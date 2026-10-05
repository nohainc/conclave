import {
  canExecuteWorkstream,
  canManageWorkstream,
  DEFAULT_WORKSTREAM_ACCESS_POLICY,
  type ProjectMembership,
  type Workstream,
} from "@conclave/core";
import {
  HttpError,
  authorizeRequest,
  authorizeWorkstreamAccess,
  discussionReferences,
  findUnapprovedWorkstreamWorkerIds,
  json,
  normalizeWorkstreamWorkConfig,
  parseJson,
  requiredString,
  sortWorkstreams,
  workstreamMetadata,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

export async function handleListProjectWorkstreams(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "projects:read",
    projectId,
    accessContext,
  );
  const projectRow = await env.CONCLAVE_DB.prepare(
    `SELECT settings_json AS settingsJson FROM projects WHERE id = ?1`,
  )
    .bind(projectId)
    .first<{ settingsJson: string | null }>();
  const settings = parseJson(projectRow?.settingsJson);

  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT workstreams.id, workstreams.project_id AS projectId,
            workstreams.name, workstreams.status,
            workstreams.access_policy_json AS accessPolicyJson,
            usage.config_json AS workConfigJson,
            workstreams.lead_user_id AS leadUserId,
            workstreams.created_at AS createdAt, workstreams.updated_at AS updatedAt
     FROM workstreams
     LEFT JOIN workstream_work_configs usage ON usage.workstream_id = workstreams.id
     WHERE workstreams.project_id = ?1 ORDER BY workstreams.created_at ASC`,
  )
    .bind(projectId)
    .all<Record<string, unknown>>();

  const membership = await env.CONCLAVE_DB.prepare(
    `SELECT id, project_id AS projectId, user_id AS userId, role,
            created_at AS createdAt, updated_at AS updatedAt
       FROM project_memberships WHERE project_id = ?1 AND user_id = ?2`,
  )
    .bind(projectId, context.userId)
    .first<ProjectMembership>();
  const raw = (rows.results ?? []).map((row) => {
    const leadUserId = String(row.leadUserId ?? "");
    const createdAt = String(row.createdAt ?? "");
    const workstream: Workstream = {
      id: String(row.id),
      projectId: String(row.projectId),
      name: String(row.name),
      status: String(row.status) as Workstream["status"],
      accessPolicy: {
        ...DEFAULT_WORKSTREAM_ACCESS_POLICY,
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
      ...workstreamMetadata(row),
      canConfigureWork: canManageWorkstream(
        context.userId,
        membership,
        workstream,
      ),
      canExecuteWork: canExecuteWorkstream(
        context.userId,
        membership,
        workstream,
      ),
    };
  });
  const workstreams = sortWorkstreams(raw, settings.workstreamOrder);
  return json({ workstreams });
}

export async function handleCreateWorkstream(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "projects:write",
    projectId,
    accessContext,
  );
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const name = requiredString(body.name, "name");
  const duplicate = await env.CONCLAVE_DB.prepare(
    `SELECT id FROM workstreams
     WHERE project_id = ?1 AND LOWER(TRIM(name)) = LOWER(TRIM(?2))
     LIMIT 1`,
  )
    .bind(projectId, name)
    .first<{ id: string }>();
  if (duplicate) {
    throw new HttpError(
      409,
      "This Project already has a Workstream with this name",
    );
  }
  const id = `workstream-${crypto.randomUUID()}`;
  const now = new Date().toISOString();
  const accessPolicy =
    typeof body.accessPolicy === "object" && body.accessPolicy !== null
      ? body.accessPolicy
      : DEFAULT_WORKSTREAM_ACCESS_POLICY;
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO workstreams
       (id, project_id, name, status, access_policy_json, lead_user_id, created_at, updated_at)
       VALUES (?1, ?2, ?3, 'active', ?4, ?5, ?6, ?6)`,
  )
    .bind(
      id,
      projectId,
      name,
      JSON.stringify(accessPolicy),
      context.userId,
      now,
    )
    .run();
  return json(
    {
      workstream: {
        ...workstreamMetadata({
          id,
          projectId,
          name,
          status: "active",
          accessPolicyJson: JSON.stringify(accessPolicy),
          leadUserId: context.userId,
          createdAt: now,
          updatedAt: now,
        }),
        canConfigureWork: true,
      },
    },
    { status: 201 },
  );
}

export async function handleUpdateWorkstream(
  request: Request,
  env: SecurityEnv,
  workstreamId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, workstream } = await authorizeWorkstreamAccess(
    request,
    env,
    workstreamId,
    "manage",
    accessContext,
  );
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const name =
    body.name === undefined
      ? workstream.name
      : requiredString(body.name, "name");
  const status =
    body.status === undefined ? workstream.status : String(body.status);
  if (
    !["active", "paused", "blocked", "completed", "archived"].includes(status)
  ) {
    throw new HttpError(400, "Unsupported Workstream status");
  }
  const accessPolicy =
    body.accessPolicy === undefined
      ? workstream.accessPolicy
      : body.accessPolicy;
  if (typeof accessPolicy !== "object" || accessPolicy === null) {
    throw new HttpError(400, "accessPolicy must be an object");
  }
  const rawWorkConfig = body.workConfig;
  let workConfig: Record<string, unknown> | undefined;
  const schedulableWorkerIds = new Set<string>();
  if (rawWorkConfig !== undefined) {
    const normalized = normalizeWorkstreamWorkConfig(rawWorkConfig);
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
         JOIN workspace_project_grants g ON g.workspace_id = i.workspace_id
         WHERE g.project_id = ?1 AND g.status = 'active'
           AND (g.expires_at IS NULL OR g.expires_at > ?2)`,
      )
        .bind(workstream.projectId, new Date().toISOString())
        .all<{ worker_id: string }>();
      const eligibleIds = new Set(
        (grants.results ?? []).map((row) => row.worker_id),
      );
      for (const workerId of eligibleIds) schedulableWorkerIds.add(workerId);
      const previousConfigRow = await env.CONCLAVE_DB.prepare(
        "SELECT config_json FROM workstream_work_configs WHERE workstream_id = ?1",
      )
        .bind(workstreamId)
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
        findUnapprovedWorkstreamWorkerIds(
          normalized.workerIds,
          eligibleIds,
          previouslyBoundIds,
        ).length > 0
      ) {
        throw new HttpError(
          409,
          "Selected Workers must belong to a Workspace with an active Project grant",
        );
      }
    }
  }
  if (name.trim().toLowerCase() !== workstream.name.trim().toLowerCase()) {
    const duplicate = await env.CONCLAVE_DB.prepare(
      `SELECT id FROM workstreams
       WHERE project_id = ?1 AND id <> ?2
         AND LOWER(TRIM(name)) = LOWER(TRIM(?3))
       LIMIT 1`,
    )
      .bind(workstream.projectId, workstreamId, name)
      .first<{ id: string }>();
    if (duplicate) {
      throw new HttpError(
        409,
        "This Project already has a Workstream with this name",
      );
    }
  }
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `UPDATE workstreams
     SET name = ?1, status = ?2, access_policy_json = ?3, updated_at = ?4
     WHERE id = ?5`,
  )
    .bind(name, status, JSON.stringify(accessPolicy), now, workstreamId)
    .run();
  if (workConfig !== undefined) {
    await env.CONCLAVE_DB.prepare(
      `INSERT INTO workstream_work_configs
         (workstream_id, config_json, updated_by_user_id, updated_at)
       VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT(workstream_id) DO UPDATE SET config_json = excluded.config_json,
         updated_by_user_id = excluded.updated_by_user_id, updated_at = excluded.updated_at`,
    )
      .bind(workstreamId, JSON.stringify(workConfig), context.userId, now)
      .run();
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
      await env.CONCLAVE_DB.prepare(
        `INSERT INTO worker_scheduling (worker_id, state, updated_by_user_id, updated_at)
         VALUES (?1, 'enabled', ?2, ?3)
         ON CONFLICT(worker_id) DO UPDATE SET state = 'enabled',
           updated_by_user_id = excluded.updated_by_user_id, updated_at = excluded.updated_at,
           drain_requested_by_user_id = NULL, drain_requested_at = NULL, drain_completed_at = NULL`,
      )
        .bind(workerId, context.userId, now)
        .run();
      await env.CONCLAVE_DB.prepare(
        `INSERT INTO worker_scheduling_audit
           (id, worker_id, actor_user_id, action, requested_at, completed_at)
         VALUES (?1, ?2, ?3, 'enabled', ?4, ?4)`,
      )
        .bind(crypto.randomUUID(), workerId, context.userId, now)
        .run();
    }
  }
  const savedWorkConfigJson =
    workConfig === undefined
      ? await env.CONCLAVE_DB.prepare(
          "SELECT config_json FROM workstream_work_configs WHERE workstream_id = ?1",
        )
          .bind(workstreamId)
          .first<{ config_json: string }>()
          .then((row) => row?.config_json)
      : JSON.stringify(workConfig);
  const member = await env.CONCLAVE_DB.prepare(
    `SELECT id, project_id AS projectId, user_id AS userId, role,
            created_at AS createdAt, updated_at AS updatedAt
       FROM project_memberships WHERE project_id = ?1 AND user_id = ?2`,
  )
    .bind(workstream.projectId, context.userId)
    .first<ProjectMembership>();
  const updatedWorkstream: Workstream = {
    ...workstream,
    name,
    status: status as Workstream["status"],
    accessPolicy: accessPolicy as Workstream["accessPolicy"],
    updatedAt: now,
  };
  return json({
    workstream: {
      ...workstreamMetadata({
        id: workstream.id,
        projectId: workstream.projectId,
        name,
        status,
        accessPolicyJson: JSON.stringify(accessPolicy),
        workConfigJson: savedWorkConfigJson,
        leadUserId: workstream.lead.userId,
        createdAt: workstream.createdAt,
        updatedAt: now,
      }),
      canConfigureWork: true,
      canExecuteWork: canExecuteWorkstream(
        context.userId,
        member,
        updatedWorkstream,
      ),
    },
    updatedByUserId: context.userId,
  });
}

export async function handleDeleteWorkstream(
  request: Request,
  env: SecurityEnv,
  workstreamId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeWorkstreamAccess(
    request,
    env,
    workstreamId,
    "manage",
    accessContext,
  );
  const result = await env.CONCLAVE_DB.prepare(
    "DELETE FROM workstreams WHERE id = ?1",
  )
    .bind(workstreamId)
    .run();
  if ((result.meta?.changes ?? 0) === 0) {
    throw new HttpError(404, "Workstream not found");
  }
  return json({ ok: true, workstreamId });
}

export async function handleListDiscussionMessages(
  request: Request,
  env: SecurityEnv,
  workstreamId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeWorkstreamAccess(
    request,
    env,
    workstreamId,
    "view",
    accessContext,
  );
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, workstream_id AS workstreamId, author_user_id AS authorUserId,
            body, references_json AS referencesJson, edited_at AS editedAt, created_at AS createdAt
     FROM discussion_messages WHERE workstream_id = ?1 ORDER BY created_at ASC`,
  )
    .bind(workstreamId)
    .all();
  return json({
    messages: (rows.results ?? []).map((row) => ({
      ...row,
      references: parseJson(
        (row as Record<string, unknown>).referencesJson,
        [],
      ),
    })),
  });
}

export async function handleCreateDiscussionMessage(
  request: Request,
  env: SecurityEnv,
  workstreamId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, projectId } = await authorizeWorkstreamAccess(
    request,
    env,
    workstreamId,
    "discuss",
    accessContext,
  );
  const body = (await request.json()) as Record<string, unknown>;
  const content = requiredString(body.body ?? body.content, "body");
  const references = discussionReferences(body.references);
  const now = new Date().toISOString();
  const id = `discussion-${crypto.randomUUID()}`;
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO discussion_messages
       (id, workstream_id, author_user_id, body, references_json, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
  )
    .bind(
      id,
      workstreamId,
      context.userId,
      content,
      JSON.stringify(references),
      now,
    )
    .run();
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO project_audit_log
       (id, project_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
     VALUES (?1, ?2, 'user', ?3, 'workstream.discussion.created', 'discussion_message', ?4, ?5, ?6)`,
  )
    .bind(
      `pa-${crypto.randomUUID()}`,
      projectId,
      context.userId,
      id,
      JSON.stringify({ workstreamId, references }),
      now,
    )
    .run();
  return json(
    {
      message: {
        id,
        workstreamId,
        authorUserId: context.userId,
        body: content,
        references,
        editedAt: null,
        createdAt: now,
      },
    },
    { status: 201 },
  );
}

export async function handleEditDiscussionMessage(
  request: Request,
  env: SecurityEnv,
  messageId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const message = await env.CONCLAVE_DB.prepare(
    `SELECT id, workstream_id AS workstreamId, author_user_id AS authorUserId,
            body, references_json AS referencesJson, edited_at AS editedAt, created_at AS createdAt
     FROM discussion_messages WHERE id = ?1`,
  )
    .bind(messageId)
    .first<Record<string, unknown>>();
  if (!message) throw new HttpError(404, "Discussion message not found");
  const { context } = await authorizeWorkstreamAccess(
    request,
    env,
    String(message.workstreamId),
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
  await env.CONCLAVE_DB.prepare(
    "UPDATE discussion_messages SET body = ?1, references_json = ?2, edited_at = ?3 WHERE id = ?4",
  )
    .bind(content, JSON.stringify(references), editedAt, messageId)
    .run();
  return json({ message: { ...message, body: content, references, editedAt } });
}
