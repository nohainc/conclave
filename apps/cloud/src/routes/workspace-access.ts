import {
  authorizeProjectMembership,
  authorizeWorkspaceOwner,
  type SecurityContext,
} from "@conclave/security";

import type { SecurityEnv } from "./http-security.js";
import { parseJson, recordAudit } from "./http-security.js";

import { HttpError, json } from "./http-security.js";

export async function disconnectWorkspaceRuntime(
  env: SecurityEnv,
  workspaceId: string,
  runtimeId: string,
): Promise<boolean> {
  const gateway = env.CONCLAVE_WORKSPACE_GATEWAY;
  if (!gateway) return false;
  try {
    const response = await gateway
      .getByName(workspaceId)
      .fetch("https://workspace-gateway/disconnect-runtime", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ runtimeId }),
      });
    if (!response.ok) return false;
    return response.ok;
  } catch {
    return false;
  }
}

export async function getWorkspaceGatewayStatus(
  env: SecurityEnv,
  workspaceId: string,
): Promise<{ online: boolean } | null> {
  const gateway = env.CONCLAVE_WORKSPACE_GATEWAY;
  if (!gateway) return null;
  try {
    const response = await gateway
      .getByName(workspaceId)
      .fetch("https://workspace-gateway/status");
    if (!response.ok) return null;
    const status = (await response.json()) as { online?: unknown };
    if (typeof status.online !== "boolean") return null;
    return { online: status.online };
  } catch {
    return null;
  }
}

export function workspaceProjectGrantMetadata(
  row: Record<string, unknown>,
): Record<string, unknown> {
  return {
    id: String(row.id),
    projectId: String(row.project_id),
    workspaceId: String(row.workspace_id),
    workspaceName:
      row.workspace_name == null ? null : String(row.workspace_name),
    workspaceOwnerUserId:
      row.owner_user_id == null ? null : String(row.owner_user_id),
    grantedByUserId: String(row.granted_by_user_id),
    status: String(row.status),
    allowedWorkerIds: parseJson(row.allowed_worker_ids_json, []),
    allowedWorkerCapabilities: parseJson(
      row.allowed_worker_capabilities_json,
      [],
    ),
    allowedPermissions: parseJson(row.allowed_permissions_json, []),
    networkPolicy: parseJson(row.network_policy_json, {}),
    concurrency: parseJson(row.concurrency_json, {}),
    budget: parseJson(row.budget_json, null),
    expiresAt: row.expires_at ?? null,
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

export async function loadWorkspaceProjectGrant(
  env: SecurityEnv,
  grantId: string,
): Promise<Record<string, unknown> | null> {
  return env.CONCLAVE_DB.prepare(
    `SELECT g.*, ew.name AS workspace_name, ew.owner_user_id
     FROM workspace_project_grants g
     JOIN execution_workspaces ew ON ew.id = g.workspace_id
     WHERE g.id = ?1`,
  )
    .bind(grantId)
    .first<Record<string, unknown>>();
}

export function grantStringArray(value: unknown, field: string): string {
  if (value === undefined) return "[]";
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new HttpError(400, `${field} must be an array of strings`);
  }
  return JSON.stringify(value);
}

export async function createWorkspaceProjectGrant(
  request: Request,
  env: SecurityEnv,
  context: SecurityContext,
  projectId: string,
  workspaceId: string,
): Promise<Response> {
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const project = await env.CONCLAVE_DB.prepare(
    "SELECT id FROM projects WHERE id = ?1",
  )
    .bind(projectId)
    .first<{ id: string }>();
  if (!project) throw new HttpError(404, "Project not found");
  const workspace = await env.CONCLAVE_DB.prepare(
    "SELECT id, owner_user_id, status FROM execution_workspaces WHERE id = ?1",
  )
    .bind(workspaceId)
    .first<{ id: string; owner_user_id: string; status: string }>();
  if (!workspace) throw new HttpError(404, "Workspace not found");
  if (
    workspace.owner_user_id !== context.userId ||
    workspace.status === "revoked"
  ) {
    throw new HttpError(
      403,
      "Only the Workspace owner can grant this Workspace",
    );
  }
  let membership: { role: string } | null = null;
  try {
    membership = await authorizeProjectMembership(
      env.CONCLAVE_DB,
      context,
      projectId,
      "projects:write",
    );
  } catch {
    // A Workspace owner may grant their own Workspace to a Project without
    // becoming a Project collaborator; the Project still controls use.
  }
  await authorizeWorkspaceOwner(
    env.CONCLAVE_DB,
    context,
    workspaceId,
    "workspace:manage",
  );
  const existingGrant = await env.CONCLAVE_DB.prepare(
    `SELECT id FROM workspace_project_grants
     WHERE project_id = ?1 AND workspace_id = ?2
       AND status IN ('active', 'suspended')
     LIMIT 1`,
  )
    .bind(projectId, workspaceId)
    .first<{ id: string }>();
  if (existingGrant) {
    throw new HttpError(
      409,
      "This Workspace is already connected to the Project",
    );
  }
  if (
    membership?.role === "collaborator" &&
    body.confirmContribution !== true
  ) {
    throw new HttpError(
      400,
      "Collaborators must explicitly confirm Workspace contribution",
    );
  }
  const allowedWorkerIds = grantStringArray(
    body.allowedWorkerIds,
    "allowedWorkerIds",
  );
  const allowedWorkerCapabilities = grantStringArray(
    body.allowedWorkerCapabilities,
    "allowedWorkerCapabilities",
  );
  const allowedPermissions = grantStringArray(
    body.allowedPermissions,
    "allowedPermissions",
  );
  const networkPolicy =
    body.networkPolicy === undefined
      ? '{"mode":"deny_all","allowedHosts":[]}'
      : JSON.stringify(body.networkPolicy);
  const concurrency =
    body.concurrency === undefined
      ? '{"maxConcurrentAssignments":1}'
      : JSON.stringify(body.concurrency);
  const budget = body.budget === undefined ? null : JSON.stringify(body.budget);
  const expiresAt = typeof body.expiresAt === "string" ? body.expiresAt : null;
  const now = new Date().toISOString();
  const id = `workspace-project-grant-${crypto.randomUUID().slice(0, 16)}`;
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO workspace_project_grants
       (id, project_id, workspace_id, granted_by_user_id, status,
        allowed_worker_ids_json,
        allowed_worker_capabilities_json, allowed_permissions_json,
        network_policy_json, concurrency_json, budget_json,
        expires_at, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, 'active', ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?12)
     ON CONFLICT(id, project_id, workspace_id) DO NOTHING`,
  )
    .bind(
      id,
      projectId,
      workspaceId,
      context.userId,
      allowedWorkerIds,
      allowedWorkerCapabilities,
      allowedPermissions,
      networkPolicy,
      concurrency,
      budget,
      expiresAt,
      now,
    )
    .run();
  await recordAudit(
    env,
    context,
    "workspace.project_grant.created",
    "workspace_project_grant",
    id,
    {
      projectId,
      workspaceId,
    },
  );
  const grant = await loadWorkspaceProjectGrant(env, id);
  return json(
    {
      grant: grant
        ? workspaceProjectGrantMetadata(grant)
        : { id, projectId, workspaceId },
    },
    { status: 201 },
  );
}
