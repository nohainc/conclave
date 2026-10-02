import { logStructured, requestIdFor } from "../observability.js";
import { MAX_ARTIFACT_UPLOAD_BYTES } from "./handlers.js";
import { SENSITIVE_OPERATIONS } from "../auth/index.js";
import {
  extractBearerToken,
  hashToken,
  computePackageDigest,
  authorizeProjectMembership,
  authorizeWorkspaceOwner,
} from "@conclave/security";
import { createEventPublisher } from "../event-publisher.js";
import {
  HttpError,
  artifactMetadata,
  artifactName,
  authorizeRequest,
  createWorkspaceProjectGrant,
  disconnectWorkspaceRuntime,
  findDesktopHumanSession,
  getWorkspaceGatewayStatus,
  grantStepUpIfRequired,
  json,
  loadWorkspaceProjectGrant,
  parseJson,
  recordAudit,
  recordPairingAuditEvent,
  requireRecentStepUp,
  requireWorkspaceContext,
  requiredString,
  securityContext,
  workspaceProjectGrantMetadata,
  workspaceOwnerContext,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

export async function handleListWorkspaceProjectGrants(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await authorizeWorkspaceOwner(
    env.CONCLAVE_DB,
    context,
    workspaceId,
    "workspace:manage",
  );
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT g.*, ew.name AS workspace_name, ew.owner_user_id
     FROM workspace_project_grants g JOIN execution_workspaces ew ON ew.id = g.workspace_id
     WHERE g.workspace_id = ?1 ORDER BY g.created_at DESC`,
  )
    .bind(workspaceId)
    .all<Record<string, unknown>>();
  return json({
    grants: (rows.results ?? []).map(workspaceProjectGrantMetadata),
  });
}

export async function handleCreateWorkspaceProjectGrant(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  projectId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  return createWorkspaceProjectGrant(
    request,
    env,
    context,
    projectId,
    workspaceId,
  );
}

export async function handleListProjectWorkspaces(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await authorizeProjectMembership(
    env.CONCLAVE_DB,
    context,
    projectId,
    "projects:read",
  );
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT g.*, ew.name AS workspace_name, ew.owner_user_id
     FROM workspace_project_grants g JOIN execution_workspaces ew ON ew.id = g.workspace_id
     WHERE g.project_id = ?1 AND g.status IN ('active', 'suspended')
       AND (g.expires_at IS NULL OR g.expires_at > ?2)
     ORDER BY ew.name`,
  )
    .bind(projectId, new Date().toISOString())
    .all<Record<string, unknown>>();
  return json({
    workspaces: (rows.results ?? []).map(workspaceProjectGrantMetadata),
  });
}

export async function handleRequestProjectWorkspace(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await authorizeProjectMembership(
    env.CONCLAVE_DB,
    context,
    projectId,
    "projects:write",
  );
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const workspaceId = requiredString(body.workspaceId, "workspaceId");
  const replayableRequest = new Request(request, {
    body: JSON.stringify(body),
  });
  return createWorkspaceProjectGrant(
    replayableRequest,
    env,
    context,
    projectId,
    workspaceId,
  );
}

export async function handleUpdateWorkspaceProjectGrant(
  request: Request,
  env: SecurityEnv,
  grantId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const existing = await loadWorkspaceProjectGrant(env, grantId);
  if (!existing) throw new HttpError(404, "Workspace Project Grant not found");
  await authorizeWorkspaceOwner(
    env.CONCLAVE_DB,
    context,
    String(existing.workspace_id),
    "workspace:manage",
  );
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const scope =
    body.scope === undefined ? String(existing.scope) : String(body.scope);
  if (
    !["project_repository", "selected_paths", "full_workspace"].includes(scope)
  )
    throw new HttpError(400, "Unsupported Workspace Project Grant scope");
  const requiresStepUp = await grantStepUpIfRequired(env, context, scope, body);
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `UPDATE workspace_project_grants SET scope = ?1, requires_step_up = ?2,
       status = COALESCE(?3, status), expires_at = COALESCE(?4, expires_at), updated_at = ?5
     WHERE id = ?6`,
  )
    .bind(
      scope,
      requiresStepUp,
      body.status === undefined ? null : String(body.status),
      typeof body.expiresAt === "string" ? body.expiresAt : null,
      now,
      grantId,
    )
    .run();
  await recordAudit(
    env,
    context,
    "workspace.project_grant.updated",
    "workspace_project_grant",
    grantId,
    { scope, status: body.status ?? existing.status },
  );
  const updated = await loadWorkspaceProjectGrant(env, grantId);
  return json({
    grant: updated ? workspaceProjectGrantMetadata(updated) : null,
  });
}

export async function handleRevokeWorkspaceProjectGrant(
  request: Request,
  env: SecurityEnv,
  grantId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const existing = await loadWorkspaceProjectGrant(env, grantId);
  if (!existing) throw new HttpError(404, "Workspace Project Grant not found");
  await authorizeWorkspaceOwner(
    env.CONCLAVE_DB,
    context,
    String(existing.workspace_id),
    "workspace:manage",
  );
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      "UPDATE workspace_project_grants SET status = 'revoked', updated_at = ?1 WHERE id = ?2",
    ).bind(now, grantId),
    env.CONCLAVE_DB.prepare(
      "UPDATE worker_assignments SET status = 'cancelled', error_json = ?1, updated_at = ?2 WHERE workspace_project_grant_id = ?3 AND status IN ('created', 'dispatched')",
    ).bind(
      JSON.stringify({
        code: "workspace_project_grant_revoked",
        cancelledAt: now,
      }),
      now,
      grantId,
    ),
  ]);
  await recordAudit(
    env,
    context,
    "workspace.project_grant.revoked",
    "workspace_project_grant",
    grantId,
    { projectId: existing.project_id, workspaceId: existing.workspace_id },
  );
  return json({ ok: true, revokedAt: now });
}
