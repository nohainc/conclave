import { conditionalJson } from "./conditional-read.js";
import { MutationIdempotency } from "./mutation-idempotency.js";
import { publishCollaborationEvent } from "../collaboration-events.js";
import {
  canExecuteThread,
  canManageThread,
  DEFAULT_THREAD_ACCESS_POLICY,
  type SpaceMembership,
  type Thread,
} from "@conclave/core";
import {
  HttpError,
  authorizeRequest,
  authorizeThreadAccess,
  discussionReferences,
  findUnapprovedThreadWorkerIds,
  json,
  normalizeThreadWorkConfig,
  parseJson,
  requiredString,
  sortThreads,
  threadMetadata,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

export async function handleListSpaceThreads(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "spaces:read",
    spaceId,
    accessContext,
  );
  const spaceRow = await env.CONCLAVE_DB.prepare(
    `SELECT settings_json AS settingsJson FROM spaces WHERE id = ?1`,
  )
    .bind(spaceId)
    .first<{ settingsJson: string | null }>();
  const settings = parseJson(spaceRow?.settingsJson);

  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT threads.id, threads.space_id AS spaceId,
            threads.name, threads.status,
            threads.access_policy_json AS accessPolicyJson,
            usage.config_json AS workConfigJson,
            threads.lead_user_id AS leadUserId,
            threads.created_at AS createdAt, threads.updated_at AS updatedAt
     FROM threads
     LEFT JOIN thread_work_configs usage ON usage.thread_id = threads.id
     WHERE threads.space_id = ?1 ORDER BY threads.created_at ASC`,
  )
    .bind(spaceId)
    .all<Record<string, unknown>>();

  const membership = await env.CONCLAVE_DB.prepare(
    `SELECT id, space_id AS spaceId, user_id AS userId, role,
            created_at AS createdAt, updated_at AS updatedAt
       FROM space_memberships WHERE space_id = ?1 AND user_id = ?2`,
  )
    .bind(spaceId, context.userId)
    .first<SpaceMembership>();
  const raw = (rows.results ?? []).map((row) => {
    const leadUserId = String(row.leadUserId ?? "");
    const createdAt = String(row.createdAt ?? "");
    const thread: Thread = {
      id: String(row.id),
      spaceId: String(row.spaceId),
      name: String(row.name),
      status: String(row.status) as Thread["status"],
      accessPolicy: {
        ...DEFAULT_THREAD_ACCESS_POLICY,
        ...parseJson(row.accessPolicyJson, {}),
      },
      lead: {
        userId: leadUserId,
        assignedAt: createdAt,
        assignedByUserId: leadUserId,
      },
      createdAt,
      updatedAt: String(row.updatedAt ?? ""),
    };
    return {
      ...threadMetadata(row),
      canConfigureWork: canManageThread(context.userId, membership, thread),
      canExecuteWork: canExecuteThread(context.userId, membership, thread),
    };
  });
  const threads = sortThreads(raw, settings.threadOrder);
  return conditionalJson(request, { threads });
}

export async function handleCreateThread(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "spaces:write",
    spaceId,
    accessContext,
  );
  const membership = await env.CONCLAVE_DB.prepare(
    "SELECT role FROM space_memberships WHERE space_id = ?1 AND user_id = ?2",
  )
    .bind(spaceId, context.userId)
    .first<{ role: string }>();
  const role = membership?.role ?? context.spaceRoles[spaceId];
  if (role !== "owner" && role !== "collaborator")
    throw new HttpError(
      403,
      "Space collaborator access is required to create a Thread",
    );
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const receipt = await MutationIdempotency.from(
    request,
    env.CONCLAVE_DB,
    context.userId,
    `space:${spaceId}:create-thread`,
    body,
  );
  const replay = await receipt?.replay();
  if (replay) return replay;
  const name = requiredString(body.name, "name");
  const duplicate = await env.CONCLAVE_DB.prepare(
    `SELECT id FROM threads
     WHERE space_id = ?1 AND LOWER(TRIM(name)) = LOWER(TRIM(?2))
     LIMIT 1`,
  )
    .bind(spaceId, name)
    .first<{ id: string }>();
  if (duplicate) {
    const concurrentReplay = await receipt?.replay();
    if (concurrentReplay) return concurrentReplay;
    throw new HttpError(409, "This Space already has a Thread with this name");
  }
  const id = `thread-${crypto.randomUUID()}`;
  const now = new Date().toISOString();
  const accessPolicy =
    typeof body.accessPolicy === "object" && body.accessPolicy !== null
      ? body.accessPolicy
      : DEFAULT_THREAD_ACCESS_POLICY;
  const mutation = env.CONCLAVE_DB.prepare(
    `INSERT INTO threads
       (id, space_id, name, status, access_policy_json, lead_user_id, created_at, updated_at)
       VALUES (?1, ?2, ?3, 'active', ?4, ?5, ?6, ?6)`,
  ).bind(id, spaceId, name, JSON.stringify(accessPolicy), context.userId, now);
  const response = {
    thread: {
      canConfigureWork: true,
      canExecuteWork: true,
      ...threadMetadata({
        id,
        spaceId,
        name,
        status: "active",
        accessPolicyJson: JSON.stringify(accessPolicy),
        leadUserId: context.userId,
        createdAt: now,
        updatedAt: now,
      }),
    },
  };
  const write = (receipts: D1PreparedStatement[]) =>
    publishCollaborationEvent(env, "thread.created", spaceId, id, {
      threadId: id,
      mutations: [...receipts, mutation],
    });
  const concurrentReplay = receipt
    ? await receipt.commit(response, 201, write)
    : (await write([]), null);
  return concurrentReplay ?? json(response, { status: 201 });
}

export async function handleUpdateThread(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, thread } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    "manage",
    accessContext,
  );
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const name =
    body.name === undefined ? thread.name : requiredString(body.name, "name");
  const status =
    body.status === undefined ? thread.status : String(body.status);
  if (
    !["active", "paused", "blocked", "completed", "archived"].includes(status)
  ) {
    throw new HttpError(400, "Unsupported Thread status");
  }
  const accessPolicy =
    body.accessPolicy === undefined ? thread.accessPolicy : body.accessPolicy;
  if (typeof accessPolicy !== "object" || accessPolicy === null) {
    throw new HttpError(400, "accessPolicy must be an object");
  }
  const rawWorkConfig = body.workConfig;
  let workConfig: Record<string, unknown> | undefined;
  const schedulableWorkerIds = new Set<string>();
  if (rawWorkConfig !== undefined) {
    const normalized = normalizeThreadWorkConfig(rawWorkConfig);
    workConfig = normalized.config;
    if (normalized.workerIds.length > 0) {
      const placeholders = normalized.workerIds
        .map((_, index) => `?${index + 1}`)
        .join(", ");
      const knownWorkers = await env.CONCLAVE_DB.prepare(
        `SELECT i.worker_id, catalog.display_name, ew.name AS workspace_name
           FROM workspace_worker_inventory i
           JOIN execution_workspaces ew ON ew.id = i.workspace_id
           LEFT JOIN worker_catalog catalog
             ON catalog.worker_type_id = i.worker_type_id
          WHERE i.worker_id IN (${placeholders})`,
      )
        .bind(...normalized.workerIds)
        .all<{
          worker_id: string;
          display_name: string | null;
          workspace_name: string;
        }>();
      const labelsByWorkerId = new Map(
        (knownWorkers.results ?? []).map((worker) => [
          worker.worker_id,
          {
            displayName: worker.display_name ?? worker.worker_id,
            workspaceName: worker.workspace_name,
          },
        ]),
      );
      const bindings = workConfig.bindings as Record<
        string,
        Record<string, unknown>
      >;
      for (const binding of Object.values(bindings)) {
        if (!binding || typeof binding !== "object") continue;
        if (
          typeof binding.workerId === "string" &&
          binding.workerLabel === undefined
        ) {
          const label = labelsByWorkerId.get(binding.workerId);
          if (label) binding.workerLabel = label;
        }
        if (
          typeof binding.fallbackWorkerId === "string" &&
          binding.fallbackWorkerLabel === undefined
        ) {
          const label = labelsByWorkerId.get(binding.fallbackWorkerId);
          if (label) binding.fallbackWorkerLabel = label;
        }
      }
      const grants = await env.CONCLAVE_DB.prepare(
        `SELECT i.worker_id FROM workspace_worker_inventory i
         JOIN workspace_space_grants g ON g.workspace_id = i.workspace_id
         WHERE g.space_id = ?1 AND g.status = 'active'
           AND (g.expires_at IS NULL OR g.expires_at > ?2)`,
      )
        .bind(thread.spaceId, new Date().toISOString())
        .all<{ worker_id: string }>();
      const eligibleIds = new Set(
        (grants.results ?? []).map((row) => row.worker_id),
      );
      for (const workerId of eligibleIds) schedulableWorkerIds.add(workerId);
      const previousConfigRow = await env.CONCLAVE_DB.prepare(
        "SELECT config_json FROM thread_work_configs WHERE thread_id = ?1",
      )
        .bind(threadId)
        .first<{ config_json: string }>();
      const previouslyBoundIds = new Set<string>();
      if (previousConfigRow?.config_json) {
        try {
          const previousConfig = JSON.parse(previousConfigRow.config_json) as {
            bindings?: Record<string, Record<string, unknown>>;
          };
          for (const binding of Object.values(previousConfig.bindings ?? {})) {
            if (!binding || typeof binding !== "object") continue;
            if (typeof binding.workerId === "string")
              previouslyBoundIds.add(binding.workerId);
            if (typeof binding.fallbackWorkerId === "string")
              previouslyBoundIds.add(binding.fallbackWorkerId);
          }
        } catch {
          // A malformed old config must not authorize new Worker references.
        }
      }
      if (
        findUnapprovedThreadWorkerIds(
          normalized.workerIds,
          eligibleIds,
          previouslyBoundIds,
        ).length > 0
      ) {
        throw new HttpError(
          409,
          "Selected Workers must belong to a Workspace with an active Space grant",
        );
      }
    }
  }
  if (name.trim().toLowerCase() !== thread.name.trim().toLowerCase()) {
    const duplicate = await env.CONCLAVE_DB.prepare(
      `SELECT id FROM threads
       WHERE space_id = ?1 AND id <> ?2
         AND LOWER(TRIM(name)) = LOWER(TRIM(?3))
       LIMIT 1`,
    )
      .bind(thread.spaceId, threadId, name)
      .first<{ id: string }>();
    if (duplicate) {
      throw new HttpError(
        409,
        "This Space already has a Thread with this name",
      );
    }
  }
  const now = new Date().toISOString();
  const mutations: D1PreparedStatement[] = [];
  mutations.push(
    env.CONCLAVE_DB.prepare(
      `UPDATE threads
     SET name = ?1, status = ?2, access_policy_json = ?3, updated_at = ?4
     WHERE id = ?5`,
    ).bind(name, status, JSON.stringify(accessPolicy), now, threadId),
  );
  if (workConfig !== undefined) {
    mutations.push(
      env.CONCLAVE_DB.prepare(
        `INSERT INTO thread_work_configs
         (thread_id, config_json, updated_by_user_id, updated_at)
       VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT(thread_id) DO UPDATE SET config_json = excluded.config_json,
         updated_by_user_id = excluded.updated_by_user_id, updated_at = excluded.updated_at`,
      ).bind(threadId, JSON.stringify(workConfig), context.userId, now),
    );
    const bindings = workConfig.bindings as Record<
      string,
      Record<string, unknown>
    >;
    const selectedWorkerIds = new Set<string>();
    for (const binding of Object.values(bindings)) {
      if (typeof binding.workerId === "string")
        selectedWorkerIds.add(binding.workerId);
      if (typeof binding.fallbackWorkerId === "string")
        selectedWorkerIds.add(binding.fallbackWorkerId);
    }
    for (const workerId of selectedWorkerIds) {
      if (!schedulableWorkerIds.has(workerId)) continue;
      mutations.push(
        env.CONCLAVE_DB.prepare(
          `INSERT INTO worker_scheduling (worker_id, state, updated_by_user_id, updated_at)
         VALUES (?1, 'enabled', ?2, ?3)
         ON CONFLICT(worker_id) DO UPDATE SET state = 'enabled',
           updated_by_user_id = excluded.updated_by_user_id, updated_at = excluded.updated_at,
           drain_requested_by_user_id = NULL, drain_requested_at = NULL, drain_completed_at = NULL`,
        ).bind(workerId, context.userId, now),
      );
      mutations.push(
        env.CONCLAVE_DB.prepare(
          `INSERT INTO worker_scheduling_audit
           (id, worker_id, actor_user_id, action, requested_at, completed_at)
         VALUES (?1, ?2, ?3, 'enabled', ?4, ?4)`,
        ).bind(crypto.randomUUID(), workerId, context.userId, now),
      );
    }
  }
  const savedWorkConfigJson =
    workConfig === undefined
      ? await env.CONCLAVE_DB.prepare(
          "SELECT config_json FROM thread_work_configs WHERE thread_id = ?1",
        )
          .bind(threadId)
          .first<{ config_json: string }>()
          .then((row) => row?.config_json)
      : JSON.stringify(workConfig);
  const member = await env.CONCLAVE_DB.prepare(
    `SELECT id, space_id AS spaceId, user_id AS userId, role,
            created_at AS createdAt, updated_at AS updatedAt
       FROM space_memberships WHERE space_id = ?1 AND user_id = ?2`,
  )
    .bind(thread.spaceId, context.userId)
    .first<SpaceMembership>();
  const updatedThread: Thread = {
    ...thread,
    name,
    status: status as Thread["status"],
    accessPolicy: accessPolicy as Thread["accessPolicy"],
    updatedAt: now,
  };
  await publishCollaborationEvent(
    env,
    "thread.updated",
    thread.spaceId,
    threadId,
    { threadId, mutations },
  );
  return json({
    thread: {
      ...threadMetadata({
        id: thread.id,
        spaceId: thread.spaceId,
        name,
        status,
        accessPolicyJson: JSON.stringify(accessPolicy),
        workConfigJson: savedWorkConfigJson,
        leadUserId: thread.lead.userId,
        createdAt: thread.createdAt,
        updatedAt: now,
      }),
      canConfigureWork: true,
      canExecuteWork: canExecuteThread(context.userId, member, updatedThread),
    },
    updatedByUserId: context.userId,
  });
}

export async function handleDeleteThread(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { spaceId } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    "manage",
    accessContext,
  );
  const mutation = env.CONCLAVE_DB.prepare(
    "DELETE FROM threads WHERE id = ?1",
  ).bind(threadId);
  await publishCollaborationEvent(env, "thread.deleted", spaceId, threadId, {
    threadId,
    mutations: [mutation],
  });
  return json({ ok: true, threadId });
}

export async function handleListDiscussionMessages(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeThreadAccess(request, env, threadId, "view", accessContext);
  const url = new URL(request.url);
  const rawLimit = url.searchParams.get("limit") ?? "50";
  if (
    !/^\d+$/.test(rawLimit) ||
    Number(rawLimit) < 1 ||
    Number(rawLimit) > 100
  ) {
    throw new HttpError(400, "Discussion limit must be between 1 and 100");
  }
  const limit = Number(rawLimit);
  const before = url.searchParams.get("before");
  const after = url.searchParams.get("after");
  if (before !== null && after !== null) {
    throw new HttpError(400, "Choose before or after, not both");
  }
  const rawCursor = before ?? after;
  let cursor: { createdAt: string; id: string } | null = null;
  if (rawCursor !== null) {
    try {
      if (rawCursor.length > 2048) throw new Error("Oversized cursor");
      const value = JSON.parse(decodeURIComponent(atob(rawCursor))) as Record<
        string,
        unknown
      >;
      if (
        value.version !== 1 ||
        value.threadId !== threadId ||
        typeof value.createdAt !== "string" ||
        !value.createdAt ||
        typeof value.id !== "string" ||
        !value.id
      )
        throw new Error("Invalid cursor");
      cursor = { createdAt: value.createdAt, id: value.id };
    } catch {
      throw new HttpError(400, "Invalid Discussion cursor");
    }
  }
  const forward = after !== null;
  const comparison = forward ? ">" : "<";
  const order = forward ? "ASC" : "DESC";
  const statement = env.CONCLAVE_DB.prepare(
    `SELECT id, thread_id AS threadId, author_user_id AS authorUserId,
            body, references_json AS referencesJson, edited_at AS editedAt, created_at AS createdAt
     FROM discussion_messages WHERE thread_id = ?1
       ${cursor ? `AND (created_at ${comparison} ?2 OR (created_at = ?2 AND id ${comparison} ?3))` : ""}
     ORDER BY created_at ${order}, id ${order} LIMIT ${cursor ? "?4" : "?2"}`,
  );
  const rows = await (
    cursor
      ? statement.bind(threadId, cursor.createdAt, cursor.id, limit + 1)
      : statement.bind(threadId, limit + 1)
  ).all<Record<string, unknown>>();
  const results = rows.results ?? [];
  const more = results.length > limit;
  const selected = results.slice(0, limit);
  const encode = (row: Record<string, unknown>) =>
    btoa(
      encodeURIComponent(
        JSON.stringify({
          version: 1,
          threadId,
          createdAt: row.createdAt,
          id: row.id,
        }),
      ),
    );
  const nextCursor =
    more && selected.length ? encode(selected[selected.length - 1]!) : null;
  const messages = forward ? selected : selected.reverse();
  return json({
    schemaVersion: 1,
    messages: messages.map((row) => ({
      ...row,
      references: parseJson(row.referencesJson, []),
    })),
    nextCursor,
    newestCursor: messages.length
      ? encode(messages[messages.length - 1]!)
      : rawCursor,
  });
}

export async function handleCreateDiscussionMessage(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, spaceId } = await authorizeThreadAccess(
    request,
    env,
    threadId,
    "discuss",
    accessContext,
  );
  const body = (await request.json()) as Record<string, unknown>;
  const receipt = await MutationIdempotency.from(
    request,
    env.CONCLAVE_DB,
    context.userId,
    `thread:${threadId}:send-discussion`,
    body,
  );
  const replay = await receipt?.replay();
  if (replay) return replay;
  const content = requiredString(body.body ?? body.content, "body");
  const references = discussionReferences(body.references);
  const now = new Date().toISOString();
  const id = `discussion-${crypto.randomUUID()}`;
  const mutations: D1PreparedStatement[] = [];
  mutations.push(
    env.CONCLAVE_DB.prepare(
      `INSERT INTO discussion_messages
       (id, thread_id, author_user_id, body, references_json, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
    ).bind(
      id,
      threadId,
      context.userId,
      content,
      JSON.stringify(references),
      now,
    ),
  );
  mutations.push(
    env.CONCLAVE_DB.prepare(
      `INSERT INTO space_audit_log
       (id, space_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
     VALUES (?1, ?2, 'user', ?3, 'thread.discussion.created', 'discussion_message', ?4, ?5, ?6)`,
    ).bind(
      `pa-${crypto.randomUUID()}`,
      spaceId,
      context.userId,
      id,
      JSON.stringify({ threadId, references }),
      now,
    ),
  );
  const response = {
    message: {
      id,
      threadId,
      authorUserId: context.userId,
      body: content,
      references,
      editedAt: null,
      createdAt: now,
    },
  };
  const write = (receipts: D1PreparedStatement[]) =>
    publishCollaborationEvent(env, "discussion.created", spaceId, id, {
      threadId,
      mutations: [...receipts, ...mutations],
    });
  const concurrentReplay = receipt
    ? await receipt.commit(response, 201, write)
    : (await write([]), null);
  return concurrentReplay ?? json(response, { status: 201 });
}

export async function handleGetDiscussionMessage(
  request: Request,
  env: SecurityEnv,
  messageId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const message = await env.CONCLAVE_DB.prepare(
    `SELECT id, thread_id AS threadId, author_user_id AS authorUserId,
      body, references_json AS referencesJson, edited_at AS editedAt, created_at AS createdAt
     FROM discussion_messages WHERE id = ?1`,
  )
    .bind(messageId)
    .first<Record<string, unknown>>();
  if (!message) throw new HttpError(404, "Discussion message not found");
  await authorizeThreadAccess(
    request,
    env,
    String(message.threadId),
    "view",
    accessContext,
  );
  return json({
    message: { ...message, references: parseJson(message.referencesJson, []) },
  });
}

export async function handleEditDiscussionMessage(
  request: Request,
  env: SecurityEnv,
  messageId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const message = await env.CONCLAVE_DB.prepare(
    `SELECT id, thread_id AS threadId, author_user_id AS authorUserId,
            body, references_json AS referencesJson, edited_at AS editedAt, created_at AS createdAt
     FROM discussion_messages WHERE id = ?1`,
  )
    .bind(messageId)
    .first<Record<string, unknown>>();
  if (!message) throw new HttpError(404, "Discussion message not found");
  const { context, spaceId } = await authorizeThreadAccess(
    request,
    env,
    String(message.threadId),
    "discuss",
    accessContext,
  );
  if (String(message.authorUserId) !== context.userId)
    throw new HttpError(403, "Only the message author may edit it");
  const body = (await request.json()) as Record<string, unknown>;
  const content = requiredString(body.body ?? body.content, "body");
  const references = discussionReferences(
    body.references ?? parseJson(message.referencesJson, []),
  );
  const editedAt = new Date().toISOString();
  const mutation = env.CONCLAVE_DB.prepare(
    "UPDATE discussion_messages SET body = ?1, references_json = ?2, edited_at = ?3 WHERE id = ?4",
  ).bind(content, JSON.stringify(references), editedAt, messageId);
  await publishCollaborationEvent(
    env,
    "discussion.updated",
    spaceId,
    messageId,
    { threadId: String(message.threadId), mutations: [mutation] },
  );
  return json({ message: { ...message, body: content, references, editedAt } });
}
