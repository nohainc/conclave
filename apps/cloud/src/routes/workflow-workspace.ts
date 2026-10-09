import { publishCollaborationEvent } from "../collaboration-events.js";
import {
  securityContext,
  HttpError,
  json,
  type SecurityEnv,
} from "./http-security.js";

export async function loadWorkflowWorkspace(
  env: Pick<SecurityEnv, "CONCLAVE_DB">,
  userId: string,
  spaceId?: string,
) {
  const global = await env.CONCLAVE_DB.prepare(
    "SELECT workspace_id AS workspaceId FROM user_workflow_settings WHERE user_id = ?1",
  )
    .bind(userId)
    .first<{ workspaceId: string | null }>();
  const space = spaceId
    ? await env.CONCLAVE_DB.prepare(
        "SELECT workspace_id AS workspaceId FROM space_workflow_settings WHERE space_id = ?1",
      )
        .bind(spaceId)
        .first<{ workspaceId: string | null }>()
    : null;
  return {
    workspaceId: space ? space.workspaceId : (global?.workspaceId ?? null),
    inherited: Boolean(spaceId && !space),
  };
}
/** Selection is restricted to Workspaces and Spaces owned by this user. */
export async function prepareWorkflowWorkspaceGrant(
  env: SecurityEnv,
  ownerUserId: string,
  spaceId: string,
  workspaceId: string,
  now: string,
): Promise<D1PreparedStatement[]> {
  const owned = await env.CONCLAVE_DB.prepare(
    "SELECT id FROM execution_workspaces WHERE id=?1 AND owner_user_id=?2 AND status != 'revoked'",
  )
    .bind(workspaceId, ownerUserId)
    .first();
  if (!owned)
    throw new HttpError(
      403,
      "Workspace is unavailable or not owned by the settings owner",
    );
  const existing = await env.CONCLAVE_DB.prepare(
    "SELECT id,status,expires_at FROM workspace_space_grants WHERE space_id=?1 AND workspace_id=?2 AND status IN ('active','suspended')",
  )
    .bind(spaceId, workspaceId)
    .first<{ id: string; status: string; expires_at: string | null }>();
  if (
    existing?.status === "suspended" ||
    (existing?.expires_at && existing.expires_at <= now)
  )
    throw new HttpError(
      409,
      "The selected Workspace grant is suspended or expired",
    );
  const statements: D1PreparedStatement[] = [
    // Selecting a Workflow Workspace is the user-facing execution boundary.
    // Ready, locally enabled Workers there are available to Cloud scheduling;
    // no second hidden scheduling toggle is required for Workflows.
    env.CONCLAVE_DB.prepare(
      `UPDATE worker_scheduling
          SET state='enabled', updated_by_user_id=?2, updated_at=?3
        WHERE worker_id IN (
          SELECT worker_id FROM workspace_worker_inventory
           WHERE workspace_id=?1
             AND activation_state='enabled'
             AND readiness_state='ready'
        )
          AND state <> 'draining'`,
    ).bind(workspaceId, ownerUserId, now),
  ];
  if (existing) return statements;
  statements.push(
    env.CONCLAVE_DB.prepare(
      "INSERT INTO workspace_space_grants(id,space_id,workspace_id,granted_by_user_id,status,allowed_permissions_json,created_at,updated_at) VALUES(?1,?2,?3,?4,'active',?5,?6,?6)",
    ).bind(
      crypto.randomUUID(),
      spaceId,
      workspaceId,
      ownerUserId,
      JSON.stringify(["repository:read", "repository:write", "shell:execute"]),
      now,
    ),
    env.CONCLAVE_DB.prepare(
      "INSERT INTO space_audit_log(id,space_id,actor_type,actor_id,action,target_type,target_id,details_json,created_at) VALUES(?1,?2,'user',?3,'workflow.workspace.authorized','execution_workspace',?4,?5,?6)",
    ).bind(
      crypto.randomUUID(),
      spaceId,
      ownerUserId,
      workspaceId,
      JSON.stringify({ workspaceId }),
      now,
    ),
  );
  return statements;
}

export async function handleWorkflowWorkspace(
  request: Request,
  env: SecurityEnv,
  spaceId?: string,
  ctx?: ExecutionContext,
) {
  const context = await securityContext(request, env, ctx);
  let ownerUserId = context.userId;
  if (spaceId) {
    const space = await env.CONCLAVE_DB.prepare(
      "SELECT s.owner_user_id AS ownerUserId FROM spaces s JOIN space_memberships m ON m.space_id = s.id WHERE s.id = ?1 AND m.user_id = ?2",
    )
      .bind(spaceId, context.userId)
      .first<{ ownerUserId: string }>();
    if (!space) throw new HttpError(403, "Space membership required");
    ownerUserId = space.ownerUserId;
    if (request.method !== "GET" && ownerUserId !== context.userId)
      throw new HttpError(
        403,
        "Only the Space owner can select its workflow Workspace",
      );
  }
  const current = await loadWorkflowWorkspace(env, ownerUserId, spaceId);
  const choices = await env.CONCLAVE_DB.prepare(
    "SELECT id, name FROM execution_workspaces WHERE owner_user_id = ?1 AND status != 'revoked' ORDER BY name, id",
  )
    .bind(ownerUserId)
    .all<{ id: string; name: string }>();
  if (request.method === "GET") {
    if (current.workspaceId && spaceId) {
      await env.CONCLAVE_DB.batch(
        await prepareWorkflowWorkspaceGrant(
          env,
          ownerUserId,
          spaceId,
          current.workspaceId,
          new Date().toISOString(),
        ),
      );
    }
    return json({
      ...current,
      workspaces:
        context.userId === ownerUserId
          ? choices.results
          : choices.results.filter(
              (workspace) => workspace.id === current.workspaceId,
            ),
    });
  }
  if (request.method !== "PUT") throw new HttpError(405, "Unsupported method");
  const body = (await request.json().catch(() => null)) as Record<
    string,
    unknown
  >;
  if (
    !body ||
    typeof body !== "object" ||
    Array.isArray(body) ||
    Object.keys(body).some(
      (k) => !["workspaceId", "confirmReset", "inherit"].includes(k),
    ) ||
    (body.inherit !== undefined && typeof body.inherit !== "boolean")
  )
    throw new HttpError(400, "Invalid Workspace selection");
  if (body.inherit && !spaceId)
    throw new HttpError(
      400,
      "Only a Space may inherit global Workspace selection",
    );
  if (
    !body.inherit &&
    body.workspaceId !== null &&
    typeof body.workspaceId !== "string"
  )
    throw new HttpError(400, "Choose a Workspace");
  const selected = body.inherit
    ? (await loadWorkflowWorkspace(env, ownerUserId)).workspaceId
    : (body.workspaceId as string | null);
  if (selected && !choices.results.some((w) => w.id === selected))
    throw new HttpError(403, "Workspace is not owned by the settings owner");
  const changed =
    selected !== current.workspaceId ||
    Boolean(body.inherit) !== current.inherited;
  const resetToGlobal = Boolean(body.inherit && spaceId && current.inherited);
  if (!changed && !resetToGlobal)
    return json({ ...current, workspaces: choices.results });
  if (body.confirmReset !== true)
    throw new HttpError(
      409,
      "Changing Workspace resets all workflows; confirmReset is required",
    );
  const db = env.CONCLAVE_DB;
  const now = new Date().toISOString();
  const statements: D1PreparedStatement[] = [];
  if (spaceId) {
    if (body.inherit)
      statements.push(
        db
          .prepare("DELETE FROM space_workflow_settings WHERE space_id = ?1")
          .bind(spaceId),
      );
    else
      statements.push(
        db
          .prepare(
            "INSERT INTO space_workflow_settings(space_id,workspace_id,updated_at) VALUES(?1,?2,?3) ON CONFLICT(space_id) DO UPDATE SET workspace_id=excluded.workspace_id,updated_at=excluded.updated_at",
          )
          .bind(spaceId, selected, now),
      );
    statements.push(
      db
        .prepare(
          "DELETE FROM space_workflow_configurations WHERE space_id = ?1",
        )
        .bind(spaceId),
    );
    statements.push(
      db
        .prepare("DELETE FROM space_workflow_defaults WHERE space_id = ?1")
        .bind(spaceId),
    );
    if (selected)
      statements.push(
        ...(await prepareWorkflowWorkspaceGrant(
          env,
          ownerUserId,
          spaceId,
          selected,
          now,
        )),
      );
  } else {
    statements.push(
      db
        .prepare(
          "INSERT INTO user_workflow_settings(user_id,workspace_id,updated_at) VALUES(?1,?2,?3) ON CONFLICT(user_id) DO UPDATE SET workspace_id=excluded.workspace_id,updated_at=excluded.updated_at",
        )
        .bind(ownerUserId, selected, now),
    );
    statements.push(
      db
        .prepare("DELETE FROM user_workflow_configurations WHERE user_id = ?1")
        .bind(ownerUserId),
    );
    statements.push(
      db
        .prepare("DELETE FROM user_workflow_defaults WHERE user_id = ?1")
        .bind(ownerUserId),
    );
    statements.push(
      db
        .prepare(
          "DELETE FROM space_workflow_configurations WHERE space_id IN (SELECT s.id FROM spaces s WHERE s.owner_user_id=?1 AND NOT EXISTS (SELECT 1 FROM space_workflow_settings ws WHERE ws.space_id=s.id))",
        )
        .bind(ownerUserId),
    );
    statements.push(
      db
        .prepare(
          "DELETE FROM space_workflow_defaults WHERE space_id IN (SELECT s.id FROM spaces s WHERE s.owner_user_id=?1 AND NOT EXISTS (SELECT 1 FROM space_workflow_settings ws WHERE ws.space_id=s.id))",
        )
        .bind(ownerUserId),
    );
  }
  const affectedSpaces = spaceId
    ? [spaceId]
    : (
        await db
          .prepare(
            "SELECT s.id FROM spaces s WHERE s.owner_user_id=?1 AND NOT EXISTS (SELECT 1 FROM space_workflow_settings ws WHERE ws.space_id=s.id)",
          )
          .bind(ownerUserId)
          .all<{ id: string }>()
      ).results.map((space) => space.id);
  if (!spaceId && selected) {
    for (const id of affectedSpaces)
      statements.push(
        ...(await prepareWorkflowWorkspaceGrant(
          env,
          ownerUserId,
          id,
          selected,
          now,
        )),
      );
  }
  await db.batch(statements);
  for (const id of affectedSpaces)
    await publishCollaborationEvent(env, "space.updated", id, id);
  return json({
    ...(await loadWorkflowWorkspace(env, ownerUserId, spaceId)),
    workspaces: choices.results,
  });
}
