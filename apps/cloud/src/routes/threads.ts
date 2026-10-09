import {
  loadSpacePermissions,
  requireSpaceRight,
} from "./space-permissions.js";
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
            threads.lead_user_id AS leadUserId, creator.email AS creatorEmail,
            CASE WHEN threads.lead_user_id = space.owner_user_id THEN 1 ELSE 0 END AS creatorIsOwner,
            threads.created_at AS createdAt, threads.updated_at AS updatedAt
     FROM threads
     JOIN spaces space ON space.id = threads.space_id
     LEFT JOIN users creator ON creator.id = threads.lead_user_id
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
  const policy = await loadSpacePermissions(env, context.userId, spaceId);
  const effectiveMembership = membership
    ? { ...membership, permissions: policy.rights }
    : null;
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
      canConfigureWork: canManageThread(
        context.userId,
        effectiveMembership,
        thread,
      ),
      canExecuteWork: canExecuteThread(
        context.userId,
        effectiveMembership,
        thread,
      ),
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
  const creatorPolicy = await requireSpaceRight(
    env,
    context,
    spaceId,
    "manageOwnThreads",
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
        creatorEmail: context.user.email,
        creatorIsOwner: creatorPolicy.role === "owner" ? 1 : 0,
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
  if (rawWorkConfig !== undefined)
    workConfig = normalizeThreadWorkConfig(rawWorkConfig).config;
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
  const policy = await loadSpacePermissions(
    env,
    context.userId,
    thread.spaceId,
  );
  const creator = await env.CONCLAVE_DB.prepare(
    "SELECT u.email, s.owner_user_id AS ownerUserId FROM users u JOIN spaces s ON s.id = ?1 WHERE u.id = ?2",
  )
    .bind(thread.spaceId, thread.lead.userId)
    .first<{ email: string; ownerUserId: string }>();
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
        creatorEmail: creator?.email,
        creatorIsOwner: creator?.ownerUserId === thread.lead.userId ? 1 : 0,
        createdAt: thread.createdAt,
        updatedAt: now,
      }),
      canConfigureWork: true,
      canExecuteWork: canExecuteThread(
        context.userId,
        member ? { ...member, permissions: policy.rights } : null,
        updatedThread,
      ),
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
    `SELECT dm.id, dm.thread_id AS threadId, dm.author_user_id AS authorUserId,
            COALESCE(u.display_name, 'Member') AS authorName,
            dm.body, dm.references_json AS referencesJson, dm.edited_at AS editedAt, dm.created_at AS createdAt
     FROM discussion_messages dm
     LEFT JOIN users u ON u.id = dm.author_user_id
     WHERE dm.thread_id = ?1
       ${cursor ? `AND (dm.created_at ${comparison} ?2 OR (dm.created_at = ?2 AND dm.id ${comparison} ?3))` : ""}
     ORDER BY dm.created_at ${order}, dm.id ${order} LIMIT ${cursor ? "?4" : "?2"}`,
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
  const userRow = await env.CONCLAVE_DB.prepare(
    `SELECT display_name AS displayName FROM users WHERE id = ?1`,
  )
    .bind(context.userId)
    .first<{ displayName: string | null }>();
  const authorName = userRow?.displayName || "Member";
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
      authorName,
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
    `SELECT dm.id, dm.thread_id AS threadId, dm.author_user_id AS authorUserId,
      COALESCE(u.display_name, 'Member') AS authorName,
      dm.body, dm.references_json AS referencesJson, dm.edited_at AS editedAt, dm.created_at AS createdAt
     FROM discussion_messages dm
     LEFT JOIN users u ON u.id = dm.author_user_id
     WHERE dm.id = ?1`,
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
    `SELECT dm.id, dm.thread_id AS threadId, dm.author_user_id AS authorUserId,
            COALESCE(u.display_name, 'Member') AS authorName,
            dm.body, dm.references_json AS referencesJson, dm.edited_at AS editedAt, dm.created_at AS createdAt
     FROM discussion_messages dm
     LEFT JOIN users u ON u.id = dm.author_user_id
     WHERE dm.id = ?1`,
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

export async function handleDeleteDiscussionMessage(
  request: Request,
  env: SecurityEnv,
  messageId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const message = await env.CONCLAVE_DB.prepare(
    `SELECT id, thread_id AS threadId, author_user_id AS authorUserId
     FROM discussion_messages
     WHERE id = ?1`,
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
    throw new HttpError(403, "Only the message author may delete it");
  const mutation = env.CONCLAVE_DB.prepare(
    "DELETE FROM discussion_messages WHERE id = ?1",
  ).bind(messageId);
  await publishCollaborationEvent(
    env,
    "discussion.deleted",
    spaceId,
    messageId,
    { threadId: String(message.threadId), mutations: [mutation] },
  );
  return json({ success: true });
}
