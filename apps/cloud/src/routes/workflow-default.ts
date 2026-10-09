import { BUILTIN_WORKFLOW_CATALOG } from "@conclave/core";
import { loadWorkflowWorkspace } from "./workflow-workspace.js";
import { loadSpaceWorkflowConfigurations } from "./space-workflow-configurations.js";
import {
  HttpError,
  json,
  securityContext,
  type SecurityEnv,
} from "./http-security.js";

const CHAT_WORKFLOW_ID = "chat";

function definitionFor(id: string) {
  const definition = Object.values(BUILTIN_WORKFLOW_CATALOG).find(
    (entry) => entry.id === id,
  );
  if (!definition) throw new HttpError(400, "Unknown workflow");
  return definition;
}

export async function loadUserWorkflowDefault(
  env: Pick<SecurityEnv, "CONCLAVE_DB">,
  userId: string,
) {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT workflow_id AS workflowId FROM user_workflow_defaults WHERE user_id = ?1",
  )
    .bind(userId)
    .first<{ workflowId: string }>();
  return row?.workflowId ?? CHAT_WORKFLOW_ID;
}

export async function loadSpaceWorkflowDefault(
  env: Pick<SecurityEnv, "CONCLAVE_DB">,
  spaceId: string,
  ownerUserId: string,
) {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT workflow_id AS workflowId FROM space_workflow_defaults WHERE space_id = ?1",
  )
    .bind(spaceId)
    .first<{ workflowId: string }>();
  return row?.workflowId ?? loadUserWorkflowDefault(env, ownerUserId);
}

export async function handleWorkflowDefault(
  request: Request,
  env: SecurityEnv,
  spaceId?: string,
  ctx?: ExecutionContext,
) {
  const context = await securityContext(request, env, ctx);
  let ownerUserId = context.userId;
  if (spaceId) {
    const membership = await env.CONCLAVE_DB.prepare(
      `SELECT s.owner_user_id AS ownerUserId
         FROM spaces s
         JOIN space_memberships m ON m.space_id = s.id
         JOIN users u ON u.id = m.user_id
        WHERE s.id = ?1 AND m.user_id = ?2 AND u.status = 'active'`,
    )
      .bind(spaceId, context.userId)
      .first<{ ownerUserId: string }>();
    if (!membership) throw new HttpError(403, "Space membership required");
    ownerUserId = membership.ownerUserId;
    if (request.method !== "GET" && ownerUserId !== context.userId)
      throw new HttpError(403, "Only the Space owner can configure workflows");
  }

  if (request.method === "GET") {
    const selected = spaceId
      ? await loadSpaceWorkflowDefault(env, spaceId, ownerUserId)
      : await loadUserWorkflowDefault(env, ownerUserId);
    const configuration = spaceId
      ? (
          await loadSpaceWorkflowConfigurations(env, spaceId)
        ).configurations.find((value) => value.workflowId === selected)
      : JSON.parse(
          (
            await env.CONCLAVE_DB.prepare(
              "SELECT configuration_json AS configurationJson FROM user_workflow_configurations WHERE user_id = ?1 AND workflow_id = ?2",
            )
              .bind(ownerUserId, selected)
              .first<{ configurationJson: string }>()
          )?.configurationJson ?? "null",
        );
    return json({
      schemaVersion: 1,
      defaultWorkflowId:
        configuration?.enabled === false ? CHAT_WORKFLOW_ID : selected,
    });
  }
  if (request.method !== "PUT") throw new HttpError(405, "Unsupported method");
  const body = (await request.json().catch(() => null)) as Record<
    string,
    unknown
  > | null;
  if (
    !body ||
    Object.keys(body).some((key) => key !== "defaultWorkflowId") ||
    typeof body.defaultWorkflowId !== "string"
  )
    throw new HttpError(400, "Invalid default workflow selection");
  const workflowId = body.defaultWorkflowId;
  definitionFor(workflowId);
  if (workflowId !== CHAT_WORKFLOW_ID) {
    const workspace = await loadWorkflowWorkspace(env, ownerUserId, spaceId);
    if (!workspace.workspaceId)
      throw new HttpError(
        400,
        "Choose a Workspace before selecting a workflow",
      );
  }
  const configuration = spaceId
    ? (await loadSpaceWorkflowConfigurations(env, spaceId)).configurations.find(
        (value) => value.workflowId === workflowId,
      )
    : JSON.parse(
        (
          await env.CONCLAVE_DB.prepare(
            "SELECT configuration_json AS configurationJson FROM user_workflow_configurations WHERE user_id = ?1 AND workflow_id = ?2",
          )
            .bind(ownerUserId, workflowId)
            .first<{ configurationJson: string }>()
        )?.configurationJson ?? "null",
      );
  if (configuration?.enabled === false)
    throw new HttpError(
      400,
      "Disabled workflows cannot be selected as default",
    );
  const now = new Date().toISOString();
  if (spaceId) {
    await env.CONCLAVE_DB.prepare(
      `INSERT INTO space_workflow_defaults(space_id,workflow_id,updated_at)
       VALUES(?1,?2,?3)
       ON CONFLICT(space_id) DO UPDATE SET workflow_id=excluded.workflow_id,updated_at=excluded.updated_at`,
    )
      .bind(spaceId, workflowId, now)
      .run();
  } else {
    await env.CONCLAVE_DB.prepare(
      `INSERT INTO user_workflow_defaults(user_id,workflow_id,updated_at)
       VALUES(?1,?2,?3)
       ON CONFLICT(user_id) DO UPDATE SET workflow_id=excluded.workflow_id,updated_at=excluded.updated_at`,
    )
      .bind(ownerUserId, workflowId, now)
      .run();
  }
  return json({ schemaVersion: 1, defaultWorkflowId: workflowId });
}
