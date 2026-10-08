import { requireSpaceRight } from "./space-permissions.js";
import { publishCollaborationEvent } from "../collaboration-events.js";
import {
  canTransitionWorkspaceSpaceGrantStatus,
  isWorkspaceSpaceGrantStatus,
} from "@conclave/core";

import {
  authorizeSpaceMembership,
  authorizeWorkspaceOwner,
  authorizeSpaceOwner,
} from "@conclave/security";

import {
  HttpError,
  createWorkspaceSpaceGrant,
  grantExpiry,
  grantExecutionPermissions,
  json,
  loadWorkspaceSpaceGrant,
  recordAudit,
  requiredString,
  securityContext,
  workspaceSpaceGrantMetadata,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

export async function handleListWorkspaceSpaceGrants(
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
     FROM workspace_space_grants g JOIN execution_workspaces ew ON ew.id = g.workspace_id
     WHERE g.workspace_id = ?1 ORDER BY g.created_at DESC`,
  )
    .bind(workspaceId)
    .all<Record<string, unknown>>();
  return json({
    grants: (rows.results ?? []).map(workspaceSpaceGrantMetadata),
  });
}

export async function handleCreateWorkspaceSpaceGrant(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  spaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  return createWorkspaceSpaceGrant(request, env, context, spaceId, workspaceId);
}

export async function handleListSpaceWorkspaces(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await authorizeSpaceMembership(
    env.CONCLAVE_DB,
    context,
    spaceId,
    "spaces:read",
  );
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT g.*, ew.name AS workspace_name, ew.owner_user_id
     FROM workspace_space_grants g JOIN execution_workspaces ew ON ew.id = g.workspace_id
     WHERE g.space_id = ?1 AND g.status IN ('active', 'suspended')
       AND (g.expires_at IS NULL OR g.expires_at > ?2)
     ORDER BY ew.name`,
  )
    .bind(spaceId, new Date().toISOString())
    .all<Record<string, unknown>>();
  return json({
    workspaces: (rows.results ?? []).map((row) => ({
      ...workspaceSpaceGrantMetadata(row),
      canRevoke:
        row.owner_user_id === context.userId ||
        context.spaceRoles[spaceId] === "owner",
      canOpenWorkspace: row.owner_user_id === context.userId,
    })),
  });
}

export async function handleRequestSpaceWorkspace(
  request: Request,
  env: SecurityEnv,
  spaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await requireSpaceRight(env, context, spaceId, "attachWorkspace");
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const workspaceId = requiredString(body.workspaceId, "workspaceId");
  const replayableRequest = new Request(request, {
    body: JSON.stringify(body),
  });
  return createWorkspaceSpaceGrant(
    replayableRequest,
    env,
    context,
    spaceId,
    workspaceId,
  );
}

export async function handleUpdateWorkspaceSpaceGrant(
  request: Request,
  env: SecurityEnv,
  grantId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const existing = await loadWorkspaceSpaceGrant(env, grantId);
  if (!existing) throw new HttpError(404, "Workspace Space Grant not found");
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
    Object.keys(body).some(
      (key) => !["status", "expiresAt", "allowedPermissions"].includes(key),
    )
  ) {
    throw new HttpError(400, "Workspace Grant update fields are invalid");
  }
  const existingStatus = existing.status;
  if (!isWorkspaceSpaceGrantStatus(existingStatus)) {
    throw new HttpError(409, "Workspace Grant has an invalid stored status");
  }
  let status = existingStatus;
  if (body.status !== undefined) {
    if (body.status !== "active" && body.status !== "suspended") {
      throw new HttpError(400, "status must be active or suspended");
    }
    status = body.status;
    if (!canTransitionWorkspaceSpaceGrantStatus(existingStatus, status)) {
      throw new HttpError(409, "Workspace Grant status transition is invalid");
    }
  }
  const now = new Date().toISOString();
  const permissions =
    body.allowedPermissions === undefined
      ? String(existing.allowed_permissions_json)
      : grantExecutionPermissions(body.allowedPermissions);
  const expiresAt = grantExpiry(
    body.expiresAt === undefined ? existing.expires_at : body.expiresAt,
    new Date(now),
  );
  if (existingStatus !== "active" && existingStatus !== "suspended") {
    throw new HttpError(409, "Terminal Workspace Grants cannot be updated");
  }
  const updatedRow = await env.CONCLAVE_DB.prepare(
    `UPDATE workspace_space_grants SET
       status = ?1, expires_at = ?2, updated_at = ?3, allowed_permissions_json = ?6
     WHERE id = ?4 AND status = ?5`,
  )
    .bind(status, expiresAt, now, grantId, existingStatus, permissions)
    .run();
  if (updatedRow.meta?.changes === 0) {
    throw new HttpError(409, "Workspace Grant changed concurrently");
  }
  await recordAudit(
    env,
    context,
    "workspace.space_grant.updated",
    "workspace_space_grant",
    grantId,
    { status, allowedPermissions: JSON.parse(permissions) },
  );
  await publishCollaborationEvent(
    env,
    "workspace_space_grant.updated",
    String(existing.space_id),
    grantId,
    { additionalRecipientUserIds: [context.userId] },
  );
  const updated = await loadWorkspaceSpaceGrant(env, grantId);
  return json({
    grant: updated ? workspaceSpaceGrantMetadata(updated) : null,
  });
}

export async function handleRevokeWorkspaceSpaceGrant(
  request: Request,
  env: SecurityEnv,
  grantId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const existing = await loadWorkspaceSpaceGrant(env, grantId);
  if (!existing) throw new HttpError(404, "Workspace Space Grant not found");
  try {
    await authorizeWorkspaceOwner(
      env.CONCLAVE_DB,
      context,
      String(existing.workspace_id),
      "workspace:manage",
    );
  } catch {
    await authorizeSpaceOwner(
      env.CONCLAVE_DB,
      context,
      String(existing.space_id),
    );
  }
  if (!isWorkspaceSpaceGrantStatus(existing.status)) {
    throw new HttpError(409, "Workspace Grant has an invalid stored status");
  }
  if (existing.status === "revoked") {
    return json({ ok: true, revokedAt: existing.updated_at });
  }
  if (!canTransitionWorkspaceSpaceGrantStatus(existing.status, "revoked")) {
    throw new HttpError(409, "Terminal Workspace Grants cannot be revoked");
  }
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      "UPDATE workspace_space_grants SET status = 'revoked', updated_at = ?1 WHERE id = ?2 AND status = ?3",
    ).bind(now, grantId, existing.status),
    env.CONCLAVE_DB.prepare(
      "UPDATE worker_assignments SET status = 'cancelled', error_json = ?1, updated_at = ?2 WHERE workspace_space_grant_id = ?3 AND status IN ('created', 'dispatched')",
    ).bind(
      JSON.stringify({
        code: "workspace_space_grant_revoked",
        cancelledAt: now,
      }),
      now,
      grantId,
    ),
  ]);
  await recordAudit(
    env,
    context,
    "workspace.space_grant.revoked",
    "workspace_space_grant",
    grantId,
    { spaceId: existing.space_id, workspaceId: existing.workspace_id },
  );
  await publishCollaborationEvent(
    env,
    "workspace_space_grant.updated",
    String(existing.space_id),
    grantId,
    { additionalRecipientUserIds: [context.userId] },
  );
  return json({ ok: true, revokedAt: now });
}
