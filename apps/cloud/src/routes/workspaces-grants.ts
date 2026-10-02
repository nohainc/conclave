import {
  canTransitionWorkspaceProjectGrantStatus,
  isWorkspaceProjectGrantStatus,
} from "@conclave/core";

import {
  authorizeProjectMembership,
  authorizeWorkspaceOwner,
} from "@conclave/security";

import {
  HttpError,
  createWorkspaceProjectGrant,
  grantExpiry,
  json,
  loadWorkspaceProjectGrant,
  recordAudit,
  requiredString,
  securityContext,
  workspaceProjectGrantMetadata,
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
  const rawBody = await request.json().catch(() => null);
  if (!rawBody || typeof rawBody !== "object" || Array.isArray(rawBody)) {
    throw new HttpError(400, "Request body must be an object");
  }
  const body = rawBody as Record<string, unknown>;
  if (
    Object.keys(body).length === 0 ||
    Object.keys(body).some((key) => key !== "status" && key !== "expiresAt")
  ) {
    throw new HttpError(400, "Workspace Grant update fields are invalid");
  }
  const existingStatus = existing.status;
  if (!isWorkspaceProjectGrantStatus(existingStatus)) {
    throw new HttpError(409, "Workspace Grant has an invalid stored status");
  }
  let status = existingStatus;
  if (body.status !== undefined) {
    if (body.status !== "active" && body.status !== "suspended") {
      throw new HttpError(400, "status must be active or suspended");
    }
    status = body.status;
    if (!canTransitionWorkspaceProjectGrantStatus(existingStatus, status)) {
      throw new HttpError(409, "Workspace Grant status transition is invalid");
    }
  }
  const now = new Date().toISOString();
  const expiresAt = grantExpiry(
    body.expiresAt === undefined ? existing.expires_at : body.expiresAt,
    new Date(now),
  );
  if (existingStatus !== "active" && existingStatus !== "suspended") {
    throw new HttpError(409, "Terminal Workspace Grants cannot be updated");
  }
  const updatedRow = await env.CONCLAVE_DB.prepare(
    `UPDATE workspace_project_grants SET
       status = ?1, expires_at = ?2, updated_at = ?3
     WHERE id = ?4 AND status = ?5`,
  )
    .bind(status, expiresAt, now, grantId, existingStatus)
    .run();
  if (updatedRow.meta?.changes === 0) {
    throw new HttpError(409, "Workspace Grant changed concurrently");
  }
  await recordAudit(
    env,
    context,
    "workspace.project_grant.updated",
    "workspace_project_grant",
    grantId,
    { status },
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
  if (!isWorkspaceProjectGrantStatus(existing.status)) {
    throw new HttpError(409, "Workspace Grant has an invalid stored status");
  }
  if (existing.status === "revoked") {
    return json({ ok: true, revokedAt: existing.updated_at });
  }
  if (!canTransitionWorkspaceProjectGrantStatus(existing.status, "revoked")) {
    throw new HttpError(409, "Terminal Workspace Grants cannot be revoked");
  }
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      "UPDATE workspace_project_grants SET status = 'revoked', updated_at = ?1 WHERE id = ?2 AND status = ?3",
    ).bind(now, grantId, existing.status),
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
