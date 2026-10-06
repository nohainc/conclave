import {
  HttpError,
  json,
  parseJson,
  recordAudit,
  requireWorkspaceContext,
  securityContext,
  workspaceOwnerContext,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

export async function handleListWorkspaces(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT execution_workspaces.id, name, status,
            COALESCE(grants.activeProjectGrantCount, 0) AS activeProjectGrantCount,
            EXISTS (SELECT 1 FROM workspace_runtime_identities identity
                    WHERE identity.workspace_id = execution_workspaces.id
                      AND identity.revoked_at IS NULL) AS hasRuntimeIdentity,
            (SELECT COUNT(*) FROM workspace_worker_inventory worker
              WHERE worker.workspace_id = execution_workspaces.id) AS workerCount,
            (SELECT COUNT(*) FROM worker_assignments assignment
              WHERE assignment.execution_workspace_id = execution_workspaces.id
                AND assignment.status IN ('created', 'dispatched', 'acknowledged', 'running')) AS activeTaskCount,
            CASE
              WHEN NOT EXISTS (SELECT 1 FROM workspace_runtime_identities identity
                               WHERE identity.workspace_id = execution_workspaces.id
                                 AND identity.revoked_at IS NULL) THEN NULL
              WHEN f.updated_at IS NULL OR execution_workspaces.updated_at > f.updated_at
                THEN execution_workspaces.updated_at
              ELSE f.updated_at
            END AS lastSeen,
            f.platform, f.architecture, f.hostname,
            f.app_version AS appVersion,
            f.runtime_capabilities_json AS runtimeCapabilitiesJson,
            f.updated_at AS factsUpdatedAt,
            execution_workspaces.created_at AS createdAt,
            execution_workspaces.updated_at AS updatedAt
       FROM execution_workspaces
       LEFT JOIN workspace_runtime_facts f ON f.workspace_id = execution_workspaces.id
       LEFT JOIN (
         SELECT g.workspace_id, COUNT(DISTINCT g.project_id) AS activeProjectGrantCount
           FROM workspace_project_grants g
           JOIN projects p ON p.id = g.project_id
           JOIN execution_workspaces owned ON owned.id = g.workspace_id
          WHERE owned.owner_user_id = ?1 AND g.status = 'active'
            AND (g.expires_at IS NULL OR g.expires_at > ?2)
            AND COALESCE(json_extract(p.settings_json, '$.archived'), 0) = 0
          GROUP BY g.workspace_id
       ) grants ON grants.workspace_id = execution_workspaces.id
      WHERE owner_user_id = ?1 AND status <> 'revoked'
      ORDER BY name ASC`,
  )
    .bind(context.userId, new Date().toISOString())
    .all();
  const workspaces = await Promise.all(
    (rows.results ?? []).map(async (raw) => {
      const row = raw as Record<string, unknown>;
      const workspaceId = typeof row.id === "string" ? row.id : null;
      let activeTransport: "websocket" | "http_long_poll" | null = null;
      if (
        workspaceId &&
        row.hasRuntimeIdentity &&
        env.CONCLAVE_WORKSPACE_GATEWAY
      ) {
        try {
          const response = await env.CONCLAVE_WORKSPACE_GATEWAY.getByName(
            workspaceId,
          ).fetch("https://workspace-gateway/status");
          if (response.ok) {
            const status = (await response.json()) as {
              online?: boolean;
              activeTransport?: string | null;
            };
            if (
              status.online &&
              (status.activeTransport === "websocket" ||
                status.activeTransport === "http_long_poll")
            ) {
              activeTransport = status.activeTransport;
            }
          }
        } catch {
          // Connection mode is an operational hint; preserve the Workspace
          // row if its Gateway status cannot be read at this moment.
        }
      }
      return {
        ...row,
        activeTransport,
        connectionMode:
          activeTransport === "websocket"
            ? "Connected · WebSocket"
            : activeTransport === "http_long_poll"
              ? "Connected · HTTPS fallback"
              : null,
      };
    }),
  );
  return json({ workspaces });
}

export async function handleGetWorkspace(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  await requireWorkspaceContext(context, env, workspaceId);
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT id, name, status, created_at AS createdAt, updated_at AS updatedAt FROM execution_workspaces WHERE id = ?1 AND owner_user_id = ?2",
  )
    .bind(workspaceId, context.userId)
    .first<{
      id: string;
      name: string;
      status: string;
      createdAt: string;
      updatedAt: string;
    }>();
  if (!row) throw new HttpError(404, "Workspace not found");
  return json({ workspace: row });
}

export async function handleUpdateWorkspace(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await workspaceOwnerContext(
    request,
    env,
    workspaceId,
    "workspace:manage",
    accessContext,
  );
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const name = typeof body.name === "string" ? body.name.trim() : "";
  if (name.length < 1 || name.length > 120) {
    throw new HttpError(400, "Workspace name must be 1 to 120 characters");
  }
  const now = new Date().toISOString();
  const result = await env.CONCLAVE_DB.prepare(
    "UPDATE execution_workspaces SET name = ?1, updated_at = ?2 WHERE id = ?3 AND owner_user_id = ?4 AND status <> 'revoked'",
  )
    .bind(name, now, workspaceId, context.userId)
    .run();
  if (!result.success || result.meta.changes === 0) {
    throw new HttpError(404, "Workspace not found");
  }
  await recordAudit(
    env,
    context,
    "workspace.updated",
    "workspace",
    workspaceId,
    {
      name,
    },
    workspaceId,
  );
  return json({ workspace: { id: workspaceId, name, updatedAt: now } });
}

export async function handleRevokeWorkspace(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const workspace = await env.CONCLAVE_DB.prepare(
    "SELECT id, status FROM execution_workspaces WHERE id = ?1 AND owner_user_id = ?2",
  )
    .bind(workspaceId, context.userId)
    .first<{ id: string; status: string }>();
  if (!workspace) throw new HttpError(404, "Workspace not found");

  const now = new Date().toISOString();
  const alreadyRevoked = workspace.status === "revoked";
  if (!alreadyRevoked) {
    const workspaceUpdate = await env.CONCLAVE_DB.prepare(
      "UPDATE execution_workspaces SET status = 'revoked', updated_at = ?1 WHERE id = ?2 AND owner_user_id = ?3",
    )
      .bind(now, workspaceId, context.userId)
      .run();
    if (!workspaceUpdate.success || workspaceUpdate.meta.changes === 0) {
      throw new HttpError(404, "Workspace not found");
    }
  }

  await env.CONCLAVE_DB.prepare(
    "UPDATE workspace_project_grants SET status = 'revoked', updated_at = ?1 WHERE workspace_id = ?2 AND status IN ('active', 'suspended')",
  )
    .bind(now, workspaceId)
    .run();

  await env.CONCLAVE_DB.prepare(
    "UPDATE workspace_runtime_identities SET revoked_at = ?1 WHERE workspace_id = ?2 AND revoked_at IS NULL",
  )
    .bind(now, workspaceId)
    .run();

  if (!alreadyRevoked) {
    await recordAudit(
      env,
      context,
      "workspace.revoked",
      "workspace",
      workspaceId,
      { revokedAt: now },
      workspaceId,
    );
  }
  return json({ ok: true, revokedAt: now, alreadyRevoked });
}

export async function handleExportWorkspaceAudit(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await workspaceOwnerContext(
    request,
    env,
    workspaceId,
    "audit:read",
    accessContext,
  );
  const url = new URL(request.url);
  const requestedLimit = Number.parseInt(
    url.searchParams.get("limit") ?? "100",
    10,
  );
  const limit = Number.isFinite(requestedLimit)
    ? Math.min(Math.max(requestedLimit, 1), 500)
    : 100;
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, workspace_id AS workspaceId, actor_type AS actorType,
            actor_id AS actorId, action, target_type AS targetType,
            target_id AS targetId, details_json AS detailsJson,
            created_at AS createdAt
     FROM workspace_audit_log
     WHERE workspace_id = ?1
     ORDER BY created_at DESC, id DESC
     LIMIT ?2`,
  )
    .bind(workspaceId, limit)
    .all<{
      id: string;
      workspaceId: string;
      actorType: string;
      actorId: string;
      action: string;
      targetType: string;
      targetId: string;
      detailsJson: string;
      createdAt: string;
    }>();
  return json({
    format: "conclave-audit-log-v1",
    workspaceId,
    exportedAt: new Date().toISOString(),
    entries: (rows.results ?? []).map((row) => ({
      id: row.id,
      workspaceId: row.workspaceId,
      actorType: row.actorType,
      actorId: row.actorId,
      action: row.action,
      targetType: row.targetType,
      targetId: row.targetId,
      details: parseJson<Record<string, unknown>>(row.detailsJson, {}),
      createdAt: row.createdAt,
    })),
  });
}
