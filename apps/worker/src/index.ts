export { ConclaveRunWorkflow } from "./workflow.js";
export { RuntimeConnection } from "./runtime-connection.js";
export { AgentGateway } from "./agent-gateway.js";
export {
  selectWorkerForTask,
  dispatchTaskAssignment,
  recordAssignmentResult,
  recordAssignmentError,
  cancelTaskAssignment,
  type TaskToDispatch,
  type AssignmentDispatcherEnv,
} from "./assignment-dispatcher.js";
export {
  selectEnsembleCandidateWorkers,
  dispatchEnsembleTaskAssignment,
  type EnsembleDispatchParams,
  type SelectedEnsembleWorker,
} from "./ensemble-dispatcher.js";
export { handleConnectorRequest } from "./interactive-connector.js";
import {
  handleConnectorRequest,
  handleConnectorTaskRequest,
} from "./interactive-connector.js";
import {
  dispatchTaskAssignment,
  cancelTaskAssignment,
  type TaskToDispatch,
  type AssignmentDispatcherEnv,
} from "./assignment-dispatcher.js";
import {
  dispatchEnsembleTaskAssignment,
  type EnsembleDispatchParams,
} from "./ensemble-dispatcher.js";
import {
  authorize,
  extractAuthToken,
  hashToken,
  computePackageDigest,
  signPackageDigest,
  verifyPackageDigestSignature,
  resolveSecurityContextFromDb,
  type Permission,
  type Role,
  type SecurityContext,
} from "@conclave/security";
import {
  validateWorkerPluginManifest,
  compareSemver,
} from "@conclave/plugin-sdk";
import {
  AGENT_PROTOCOL_NAME,
  AGENT_PROTOCOL_VERSION,
  parseAgentMessage,
  type AgentProtocolMessage,
} from "@conclave/agent-protocol";
import {
  validateWorkspace,
  validateProject,
  validateChat,
  validateChatMessage,
  validateWorker,
  type Workspace,
  type Project,
  type Chat,
  type ChatMessage,
  type ChatMessageSenderType,
  type ChatMessageKind,
  type Worker,
  type WorkerCostMetadata,
  assembleChatContext,
  decideChatIntent,
  parseChatIntentProposal,
  recommendChatIntent,
} from "@conclave/core";
import { parseMachineCheckEvidence } from "@conclave/protocol";

function parseJson<T = Record<string, unknown>>(
  value: unknown,
  defaultValue: T = {} as T,
): T {
  if (typeof value !== "string" || value.trim().length === 0)
    return defaultValue;
  try {
    return JSON.parse(value) as T;
  } catch {
    return defaultValue;
  }
}

function json(data: unknown, init?: ResponseInit): Response {
  return Response.json(data, {
    ...init,
    headers: {
      "content-type": "application/json; charset=utf-8",
      ...init?.headers,
    },
  });
}

async function recordAudit(
  env: SecurityEnv,
  context: SecurityContext,
  action: string,
  targetType: string,
  targetId: string,
  details: Record<string, unknown> = {},
): Promise<void> {
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO audit_log
       (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
     VALUES (?1, ?2, 'user', ?3, ?4, ?5, ?6, ?7, ?8)`,
  )
    .bind(
      `audit-${crypto.randomUUID()}`,
      context.workspaceId,
      context.userId,
      action,
      targetType,
      targetId,
      JSON.stringify(details),
      new Date().toISOString(),
    )
    .run();
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Workflow operation failed";
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${field} is required`);
  }
  return value;
}

function workflowInstanceId(idempotencyKey: string): string {
  return `workflow-${idempotencyKey}`;
}

async function resolveWorkflowInstanceId(
  env: Env,
  runId: string,
  idempotencyKey?: string,
): Promise<string> {
  const run = await env.CONCLAVE_DB.prepare(
    "SELECT workflow_instance_id FROM runs WHERE id = ?1",
  )
    .bind(runId)
    .first<{ workflow_instance_id?: string | null }>();
  if (run?.workflow_instance_id) return run.workflow_instance_id;

  const external = await env.CONCLAVE_DB.prepare(
    "SELECT external_id FROM run_external_executions WHERE run_id = ?1 AND execution_kind = 'cloudflare_workflow'",
  )
    .bind(runId)
    .first<{ external_id?: string | null }>();
  if (external?.external_id) {
    await env.CONCLAVE_DB.prepare(
      "UPDATE runs SET workflow_instance_id = ?1, updated_at = ?2 WHERE id = ?3 AND workflow_instance_id IS NULL",
    )
      .bind(external.external_id, new Date().toISOString(), runId)
      .run();
    return external.external_id;
  }

  if (!idempotencyKey) {
    return workflowInstanceId(runId);
  }
  const candidate = workflowInstanceId(idempotencyKey);
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    "UPDATE runs SET workflow_instance_id = ?1, updated_at = ?2 WHERE id = ?3 AND workflow_instance_id IS NULL",
  )
    .bind(candidate, now, runId)
    .run();
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO run_external_executions
       (id, run_id, execution_kind, external_id, status, created_at, updated_at)
     VALUES (?1, ?2, 'cloudflare_workflow', ?3, 'active', ?4, ?4)
     ON CONFLICT(run_id, execution_kind) DO UPDATE SET external_id=excluded.external_id,
       updated_at=excluded.updated_at`,
  )
    .bind(`${runId}:cloudflare_workflow`, runId, candidate, now)
    .run();
  return candidate;
}

class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

type SecurityEnv = Env & {
  readonly CONCLAVE_ACCESS_ORGANIZATION_ID?: string;
  readonly CONCLAVE_AUTH_TOKEN?: string;
  readonly CONCLAVE_PLUGIN_SIGNING_KEY?: string;
  readonly CONCLAVE_AGENT_SIGNING_KEY?: string;
  readonly CONCLAVE_SECURITY_KEY?: string;
  readonly CONCLAVE_AUTH_USER_ID?: string;
  readonly CONCLAVE_AUTH_ORGANIZATION_ID?: string;
  readonly CONCLAVE_ALLOW_ANONYMOUS_DEV?: string;
  readonly CONCLAVE_CI_INGEST_TOKEN?: string;
  readonly CONCLAVE_FORGE_CALLBACK_TOKEN?: string;
  readonly CONCLAVE_RUNTIME_CONNECT_TOKEN?: string;
  readonly CONCLAVE_RUNTIME_OPERATION_TOKEN?: string;
  readonly CONCLAVE_RUNTIME_CONNECTION: DurableObjectNamespace;
  readonly CONCLAVE_AGENT_GATEWAY: DurableObjectNamespace;
  readonly CONCLAVE_CONNECTOR_REGISTRATION_TOKEN?: string;
};

function anonymousDevelopment(env: SecurityEnv): boolean {
  return (
    env.CONCLAVE_ENVIRONMENT === "development" &&
    env.CONCLAVE_ALLOW_ANONYMOUS_DEV === "true"
  );
}

function bearer(request: Request): string | null {
  const value = request.headers.get("authorization");
  return value?.startsWith("Bearer ") ? value.slice(7) : null;
}

function createDefaultSecurityContext(
  userId = "local-development",
  workspaceId = "local-development",
  role: Role = "owner",
): SecurityContext {
  return {
    userId,
    user: {
      id: userId,
      email: `${userId}@local`,
      displayName: "Developer",
      status: "active",
    },
    workspaceId,
    workspaceRole: role,
    roles: [role],
    authorizedProjectIds: [],
    projectRoles: {},
    sessionId: `session-${userId}`,
    clientType: "desktop",
    organizationId: workspaceId,
    organizationRoles: [role],
  };
}

async function accessSecurityContext(
  env: SecurityEnv,
  accessContext: ExecutionContext | undefined,
): Promise<SecurityContext> {
  const identity = await accessContext?.access?.getIdentity();
  const userId = identity?.email?.trim().toLowerCase();
  if (!userId)
    throw new HttpError(401, "Cloudflare Access authentication required");

  const targetOrgOrWs = env.CONCLAVE_ACCESS_ORGANIZATION_ID;
  const membershipQuery = targetOrgOrWs
    ? `SELECT u.id AS user_id, u.email, u.display_name, u.status AS user_status,
              wm.workspace_id, wm.role, wm.status, w.status AS workspace_status
       FROM workspace_memberships wm
       JOIN users u ON u.id = wm.user_id
       JOIN workspaces w ON w.id = wm.workspace_id
       WHERE wm.workspace_id = ?1 AND u.email = ?2`
    : `SELECT u.id AS user_id, u.email, u.display_name, u.status AS user_status,
              wm.workspace_id, wm.role, wm.status, w.status AS workspace_status
       FROM workspace_memberships wm
       JOIN users u ON u.id = wm.user_id
       JOIN workspaces w ON w.id = wm.workspace_id
       WHERE u.email = ?1`;
  type AccessMembership = {
    user_id: string;
    email: string;
    display_name: string;
    user_status: string;
    workspace_id: string;
    role: string;
    status?: string;
    workspace_status?: string;
  };
  let memberships: { results?: readonly AccessMembership[] };
  try {
    const statement = env.CONCLAVE_DB.prepare(membershipQuery);
    memberships = targetOrgOrWs
      ? await statement.bind(targetOrgOrWs, userId).all<AccessMembership>()
      : await statement.bind(userId).all<AccessMembership>();
  } catch {
    // Older development databases do not yet have membership status.
    const legacyMembershipQuery = targetOrgOrWs
      ? `SELECT u.id AS user_id, u.email, u.display_name, u.status AS user_status,
                wm.workspace_id, wm.role, w.status AS workspace_status
         FROM workspace_memberships wm
         JOIN users u ON u.id = wm.user_id
         JOIN workspaces w ON w.id = wm.workspace_id
         WHERE wm.workspace_id = ?1 AND u.email = ?2`
      : `SELECT u.id AS user_id, u.email, u.display_name, u.status AS user_status,
                wm.workspace_id, wm.role, w.status AS workspace_status
         FROM workspace_memberships wm
         JOIN users u ON u.id = wm.user_id
         JOIN workspaces w ON w.id = wm.workspace_id
         WHERE u.email = ?1`;
    const statement = env.CONCLAVE_DB.prepare(legacyMembershipQuery);
    memberships = targetOrgOrWs
      ? await statement.bind(targetOrgOrWs, userId).all<AccessMembership>()
      : await statement.bind(userId).all<AccessMembership>();
  }
  const activeMemberships = (memberships.results ?? []).filter(
    (m) =>
      (m.status === undefined || m.status === "active") &&
      (m.workspace_status === undefined || m.workspace_status === "active"),
  );
  if (activeMemberships.length !== 1)
    throw new HttpError(
      activeMemberships.length === 0 ? 403 : 409,
      activeMemberships.length === 0
        ? "Workspace membership is not active"
        : "A workspace must be selected for this identity",
    );
  const membership = activeMemberships[0]!;
  const wsId = membership.workspace_id;
  if (membership.user_status !== "active")
    throw new HttpError(403, "User account is not active");
  const resolvedUserId = membership.user_id;
  const projects = await env.CONCLAVE_DB.prepare(
    "SELECT pm.project_id, pm.role FROM project_memberships pm JOIN projects p ON p.id = pm.project_id WHERE p.workspace_id = ?1 AND pm.user_id = ?2",
  )
    .bind(wsId, resolvedUserId)
    .all<{ project_id: string; role: string }>();
  const projectRoles: Record<string, "lead" | "collaborator" | "viewer"> = {};
  for (const project of projects.results ?? [])
    projectRoles[project.project_id] = project.role as
      "lead" | "collaborator" | "viewer";
  return {
    userId: resolvedUserId,
    user: {
      id: resolvedUserId,
      email: membership.email,
      displayName: membership.display_name,
      status: "active",
    },
    workspaceId: wsId,
    workspaceRole: membership.role as Role,
    roles: [membership.role as Role],
    authorizedProjectIds: Object.keys(projectRoles),
    projectRoles,
    sessionId: `access-${userId}`,
    clientType: "web",
    organizationId: wsId,
    organizationRoles: [membership.role as Role],
  };
}

async function securityContext(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<SecurityContext> {
  const token = extractAuthToken(request.headers);
  if (token && env.CONCLAVE_DB) {
    try {
      const requestedWorkspaceId =
        request.headers.get("x-conclave-workspace-id") ??
        new URL(request.url).searchParams.get("workspaceId") ??
        undefined;
      return await resolveSecurityContextFromDb(env.CONCLAVE_DB, token, {
        requestedWorkspaceId,
      });
    } catch (err: unknown) {
      if (
        err instanceof Error &&
        "code" in err &&
        (err as { code: string }).code === "UNAUTHORIZED"
      ) {
        throw new HttpError(401, err.message);
      }
      if (
        err instanceof Error &&
        "code" in err &&
        (err as { code: string }).code === "FORBIDDEN"
      ) {
        throw new HttpError(403, err.message);
      }
      throw err;
    }
  }
  if (anonymousDevelopment(env)) {
    return createDefaultSecurityContext(
      "local-development",
      "local-development",
      "owner",
    );
  }
  if (env.CONCLAVE_ENVIRONMENT === "development" && env.CONCLAVE_AUTH_TOKEN) {
    const devToken = bearer(request);
    if (!devToken || devToken !== env.CONCLAVE_AUTH_TOKEN)
      throw new HttpError(401, "Authentication required");
    const userId = env.CONCLAVE_AUTH_USER_ID ?? "dev-user";
    const organizationId = env.CONCLAVE_AUTH_ORGANIZATION_ID ?? "dev-workspace";
    return createDefaultSecurityContext(userId, organizationId, "owner");
  }
  return accessSecurityContext(env, accessContext);
}

async function authorizeRequest(
  request: Request,
  env: SecurityEnv,
  permission: Permission,
  projectId?: string,
  accessContext?: ExecutionContext,
): Promise<SecurityContext> {
  const context = await securityContext(request, env, accessContext);
  if (projectId && !anonymousDevelopment(env)) {
    const project = await env.CONCLAVE_DB.prepare(
      "SELECT workspace_id FROM projects WHERE id = ?1",
    )
      .bind(projectId)
      .first<{
        workspace_id?: string | null;
      }>();
    const ownerWorkspace = project?.workspace_id;
    if (!project || ownerWorkspace !== context.workspaceId)
      throw new HttpError(404, "Resource not found");
  }
  try {
    authorize(context, permission, projectId);
  } catch (error) {
    throw new HttpError(
      403,
      error instanceof Error ? error.message : "Forbidden",
    );
  }
  return context;
}

function requireWorkspaceContext(
  context: SecurityContext,
  env: SecurityEnv,
  workspaceId: string,
): void {
  if (!anonymousDevelopment(env) && context.workspaceId !== workspaceId) {
    throw new HttpError(404, "Resource not found");
  }
}

function requireCiAuthentication(request: Request, env: SecurityEnv): void {
  const configuredToken = env.CONCLAVE_CI_INGEST_TOKEN;
  if (anonymousDevelopment(env) && !configuredToken) return;
  if (!configuredToken || bearer(request) !== configuredToken)
    throw new HttpError(401, "CI evidence authentication required");
}

function requireForgeCallbackAuthentication(
  request: Request,
  env: SecurityEnv,
): void {
  if (anonymousDevelopment(env) && !env.CONCLAVE_FORGE_CALLBACK_TOKEN) return;
  if (
    !env.CONCLAVE_FORGE_CALLBACK_TOKEN ||
    bearer(request) !== env.CONCLAVE_FORGE_CALLBACK_TOKEN
  ) {
    throw new HttpError(401, "Forge callback authentication required");
  }
}

function runtimeToken(
  request: Request,
  env: SecurityEnv,
  tokenName: keyof SecurityEnv,
): void {
  const configured = env[tokenName];
  const provided =
    bearer(request) ?? new URL(request.url).searchParams.get("token");
  if (!configured || provided !== configured) {
    throw new HttpError(401, "Runtime authentication required");
  }
}

function runtimeConnectionId(request: Request): string {
  const value = request.headers.get("x-conclave-runtime-id");
  if (!value || !/^[a-zA-Z0-9_-]{1,100}$/.test(value)) {
    throw new HttpError(400, "Runtime connection ID is required");
  }
  return value;
}

async function runProjectId(
  env: SecurityEnv,
  runId: string,
): Promise<string | undefined> {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT p.id AS project_id FROM runs r JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE r.id = ?1",
  )
    .bind(runId)
    .first<{ project_id: string }>();
  return row?.project_id;
}

async function goalProjectId(
  env: SecurityEnv,
  goalId: string,
): Promise<string | undefined> {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT project_id FROM goals WHERE id = ?1",
  )
    .bind(goalId)
    .first<{ project_id: string }>();
  return row?.project_id;
}

async function createOrGetRun(
  env: Env,
  params: ConclaveWorkflowParams,
): Promise<{ id: string; status: unknown }> {
  const current = await env.CONCLAVE_DB.prepare(
    "SELECT policy_snapshot_json FROM runs WHERE id = ?1",
  )
    .bind(params.runId)
    .first<{ policy_snapshot_json: string }>();
  let policy: Record<string, unknown> = {};
  if (current?.policy_snapshot_json) {
    try {
      const parsed: unknown = JSON.parse(current.policy_snapshot_json);
      if (typeof parsed === "object" && parsed !== null)
        policy = parsed as Record<string, unknown>;
    } catch {
      policy = {};
    }
  }
  await env.CONCLAVE_DB.prepare(
    "UPDATE runs SET policy_snapshot_json = ?1, updated_at = ?2 WHERE id = ?3",
  )
    .bind(
      JSON.stringify({
        ...policy,
        ...(params.repositoryId ? { repositoryId: params.repositoryId } : {}),
        ...(params.expectedCommitSha
          ? { expectedCommitSha: params.expectedCommitSha }
          : {}),
        ...(params.expectedChecks
          ? { expectedChecks: params.expectedChecks }
          : {}),
        ...(params.allowedWorkflows
          ? { allowedWorkflows: params.allowedWorkflows }
          : {}),
      }),
      new Date().toISOString(),
      params.runId,
    )
    .run();
  const id = await resolveWorkflowInstanceId(
    env,
    params.runId,
    params.idempotencyKey,
  );
  try {
    const instance = await env.CONCLAVE_RUN_WORKFLOW.create({ id, params });
    return { id: params.runId, status: (await instance.status()).status };
  } catch (error) {
    if (!errorMessage(error).toLowerCase().includes("exist")) throw error;
    const instance = await env.CONCLAVE_RUN_WORKFLOW.get(id);
    return { id: params.runId, status: (await instance.status()).status };
  }
}

type ConclaveWorkflowParams = import("./workflow.js").ConclaveWorkflowParams;

async function handleRunRequest(
  request: Request,
  env: Env,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const securityEnv = env as SecurityEnv;
  const body = (await request.json()) as Record<string, unknown>;
  const idempotencyKey = requiredString(
    request.headers.get("idempotency-key") ?? body.idempotencyKey,
    "idempotencyKey",
  );
  if (!/^[a-zA-Z0-9_-]{1,80}$/.test(idempotencyKey)) {
    throw new Error("idempotencyKey must contain only letters, digits, _ or -");
  }
  const goalId = requiredString(body.goalId, "goalId");
  const context = await authorizeRequest(
    request,
    securityEnv,
    "run:create",
    undefined,
    accessContext,
  );
  const projectId = anonymousDevelopment(securityEnv)
    ? undefined
    : await goalProjectId(securityEnv, goalId);
  await authorizeRequest(
    request,
    securityEnv,
    "run:create",
    projectId,
    accessContext,
  );
  const expectedCommitSha =
    typeof body.commitSha === "string"
      ? body.commitSha
      : typeof body.revision === "string" &&
          /^[a-f0-9]{7,64}$/i.test(body.revision)
        ? body.revision
        : undefined;
  if (body.requireCiEvidence !== false && !expectedCommitSha) {
    throw new HttpError(
      400,
      "A commitSha is required when CI evidence is enabled",
    );
  }
  if (expectedCommitSha && !/^[a-f0-9]{7,64}$/i.test(expectedCommitSha)) {
    throw new HttpError(400, "commitSha must be a hexadecimal Git commit SHA");
  }
  const params: ConclaveWorkflowParams = {
    runId: requiredString(body.runId, "runId"),
    goalId,
    idempotencyKey,
    organizationId: context.organizationId,
    ...(typeof body.repositoryId === "string"
      ? { repositoryId: body.repositoryId }
      : {}),
    ...(typeof body.revision === "string" ? { revision: body.revision } : {}),
    ...(expectedCommitSha ? { expectedCommitSha } : {}),
    ...(Array.isArray(body.expectedChecks)
      ? {
          expectedChecks: body.expectedChecks.filter(
            (value): value is string => typeof value === "string",
          ),
        }
      : {}),
    ...(Array.isArray(body.allowedWorkflows)
      ? {
          allowedWorkflows: body.allowedWorkflows.filter(
            (value): value is string => typeof value === "string",
          ),
        }
      : { allowedWorkflows: ["CI"] }),
    ...(body.requireApproval === true ? { requireApproval: true } : {}),
    ...(body.requireCiEvidence === false ? { requireCiEvidence: false } : {}),
    ...(body.startPaused === true ? { startPaused: true } : {}),
  };
  const run = await createOrGetRun(env, params);
  return json(run, { status: 202 });
}

async function handleGoalRequest(
  request: Request,
  env: Env,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const securityEnv = env as SecurityEnv;
  const body = (await request.json()) as Record<string, unknown>;
  const projectId = requiredString(body.projectId, "projectId");
  const context = await authorizeRequest(
    request,
    securityEnv,
    "project:write",
    projectId,
    accessContext,
  );
  const objective = requiredString(body.objective, "objective");
  const chatId =
    typeof body.chatId === "string" && body.chatId.trim().length > 0
      ? body.chatId.trim()
      : null;

  if (chatId && !anonymousDevelopment(securityEnv)) {
    const chat = await env.CONCLAVE_DB.prepare(
      "SELECT id, project_id, workspace_id FROM chats WHERE id = ?1",
    )
      .bind(chatId)
      .first<{ id: string; project_id: string; workspace_id: string }>();
    if (!chat || chat.project_id !== projectId) {
      throw new HttpError(404, "Chat not found in this project");
    }
  }

  const repositoryId =
    typeof body.repositoryId === "string" ? body.repositoryId : undefined;
  const revision = typeof body.revision === "string" ? body.revision : "HEAD";
  const commitSha = requiredString(body.commitSha, "commitSha");
  if (!/^[a-f0-9]{7,64}$/i.test(commitSha))
    throw new HttpError(400, "commitSha must be a hexadecimal Git commit SHA");
  const criteria = Array.isArray(body.criteria)
    ? body.criteria.filter(
        (criterion): criterion is string =>
          typeof criterion === "string" && criterion.trim().length > 0,
      )
    : [objective];
  const now = new Date().toISOString();
  const goalId = `goal-${crypto.randomUUID()}`;
  const runId = `run-${crypto.randomUUID()}`;
  const criterionRows = criteria.map((description, index) => ({
    id: `${goalId}-criterion-${index + 1}`,
    description,
  }));
  const goal = {
    id: goalId,
    workspaceId: context.workspaceId,
    projectId,
    chatId,
    createdByUserId: context.userId,
    originalMessage: objective,
    objective,
    constraints: [],
    completionCriteria: criterionRows.map((criterion) => criterion.id),
    verificationPolicy: { mode: "standard" },
    status: "running",
    createdAt: now,
    updatedAt: now,
  };
  const statements = [
    env.CONCLAVE_DB.prepare(
      `INSERT INTO goals (id, workspace_id, project_id, chat_id, created_by_user_id, original_message, objective, constraints_json, completion_criteria_json, verification_policy_json, status, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?12)`,
    ).bind(
      goal.id,
      goal.workspaceId,
      goal.projectId,
      goal.chatId,
      goal.createdByUserId,
      goal.originalMessage,
      goal.objective,
      JSON.stringify(goal.constraints),
      JSON.stringify(goal.completionCriteria),
      JSON.stringify(goal.verificationPolicy),
      goal.status,
      now,
    ),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO runs (id, workspace_id, project_id, goal_id, policy_snapshot_json, status, started_at, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, 'running', ?6, ?6, ?6)`,
    ).bind(
      runId,
      goal.workspaceId,
      goal.projectId,
      goalId,
      JSON.stringify(goal.verificationPolicy),
      now,
    ),
    ...criterionRows.map((criterion) =>
      env.CONCLAVE_DB.prepare(
        `INSERT INTO completion_criteria (id, goal_id, description, verification_requirement, status, evidence_artifact_ids_json, created_at, updated_at)
           VALUES (?1, ?2, ?3, 'independent verification', 'pending', '[]', ?4, ?4)`,
      ).bind(criterion.id, goalId, criterion.description, now),
    ),
  ];

  if (chatId) {
    statements.push(
      env.CONCLAVE_DB.prepare(
        `INSERT INTO chat_messages (id, chat_id, sender_type, sender_id, content, kind, goal_id, metadata_json, created_at)
           VALUES (?1, ?2, 'conclave', 'conclave', ?3, 'status', ?4, '{}', ?5)`,
      ).bind(
        `msg-${crypto.randomUUID()}`,
        chatId,
        `Started goal: ${objective}`,
        goalId,
        now,
      ),
      env.CONCLAVE_DB.prepare(
        "UPDATE chats SET updated_at = ?1 WHERE id = ?2",
      ).bind(now, chatId),
    );
  }

  await env.CONCLAVE_DB.batch(statements);
  const run = await createOrGetRun(env, {
    runId,
    goalId,
    idempotencyKey: runId,
    organizationId: context.organizationId,
    ...(repositoryId ? { repositoryId } : {}),
    ...(revision ? { revision } : {}),
    ...(commitSha ? { expectedCommitSha: commitSha } : {}),
    allowedWorkflows: ["CI"],
  });
  return json(
    { goalId, runId, ...(chatId ? { chatId } : {}), ...run },
    { status: 202 },
  );
}

// =========================================================================
// Workspaces API Handlers
// =========================================================================

async function handleListWorkspaces(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  if (anonymousDevelopment(env)) {
    return json({
      workspaces: [
        {
          id: context.workspaceId,
          name: "Local Development Workspace",
          slug: "local-dev",
          status: "active",
          role: context.workspaceRole,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
        },
      ],
    });
  }
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT w.id, w.name, w.slug, w.status, wm.role, w.created_at AS createdAt, w.updated_at AS updatedAt
     FROM workspaces w
     JOIN workspace_memberships wm ON wm.workspace_id = w.id
     WHERE wm.user_id = ?1 AND w.status = 'active'
     ORDER BY w.name ASC`,
  )
    .bind(context.userId)
    .all<{
      id: string;
      name: string;
      slug: string;
      status: string;
      role: string;
      createdAt: string;
      updatedAt: string;
    }>();
  return json({ workspaces: rows.results ?? [] });
}

async function handleCreateWorkspace(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const body = (await request.json()) as Record<string, unknown>;
  const name = requiredString(body.name, "name");
  const slug =
    typeof body.slug === "string" && body.slug.trim().length > 0
      ? body.slug
          .trim()
          .toLowerCase()
          .replace(/[^a-z0-9_-]/g, "-")
      : `${name.toLowerCase().replace(/[^a-z0-9_-]/g, "-")}-${crypto.randomUUID().slice(0, 6)}`;
  const now = new Date().toISOString();
  const id = `ws-${crypto.randomUUID()}`;
  const workspace: Workspace = {
    id,
    name,
    slug,
    createdAt: now,
    updatedAt: now,
  };
  validateWorkspace(workspace);

  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      "INSERT INTO workspaces (id, name, slug, status, created_at, updated_at) VALUES (?1, ?2, ?3, 'active', ?4, ?4)",
    ).bind(id, name, slug, now),
    env.CONCLAVE_DB.prepare(
      "INSERT INTO workspace_memberships (id, workspace_id, user_id, role, created_at, updated_at) VALUES (?1, ?2, ?3, 'owner', ?4, ?4)",
    ).bind(`wm-${crypto.randomUUID()}`, id, context.userId, now),
  ]);

  return json(
    { workspace: { ...workspace, status: "active", role: "owner" } },
    { status: 201 },
  );
}

async function handleGetWorkspace(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  if (context.workspaceId !== workspaceId && !anonymousDevelopment(env)) {
    const membership = await env.CONCLAVE_DB.prepare(
      "SELECT role FROM workspace_memberships WHERE workspace_id = ?1 AND user_id = ?2",
    )
      .bind(workspaceId, context.userId)
      .first<{ role: string }>();
    if (!membership) throw new HttpError(404, "Workspace not found");
  }
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT id, name, slug, status, created_at AS createdAt, updated_at AS updatedAt FROM workspaces WHERE id = ?1",
  )
    .bind(workspaceId)
    .first<{
      id: string;
      name: string;
      slug: string;
      status: string;
      createdAt: string;
      updatedAt: string;
    }>();
  if (!row) throw new HttpError(404, "Workspace not found");
  return json({ workspace: row });
}

async function handleExportWorkspaceAudit(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await workspaceMemberContext(
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
            ip_address AS ipAddress, created_at AS createdAt
     FROM audit_log
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
      ipAddress: string | null;
      createdAt: string;
    }>();
  return json({
    format: "conclave-audit-log-v1",
    workspaceId: context.workspaceId,
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
      ipAddress: row.ipAddress,
      createdAt: row.createdAt,
    })),
  });
}

type WorkspaceBackupQuery = {
  readonly name: string;
  readonly sql: string;
};

const WORKSPACE_BACKUP_QUERIES: readonly WorkspaceBackupQuery[] = [
  { name: "workspaces", sql: "SELECT * FROM workspaces WHERE id = ?1" },
  {
    name: "workspace_memberships",
    sql: "SELECT * FROM workspace_memberships WHERE workspace_id = ?1",
  },
  {
    name: "workspace_invitations",
    sql: "SELECT * FROM workspace_invitations WHERE workspace_id = ?1",
  },
  { name: "projects", sql: "SELECT * FROM projects WHERE workspace_id = ?1" },
  {
    name: "project_memberships",
    sql: "SELECT pm.* FROM project_memberships pm JOIN projects p ON p.id = pm.project_id WHERE p.workspace_id = ?1",
  },
  { name: "chats", sql: "SELECT * FROM chats WHERE workspace_id = ?1" },
  { name: "goals", sql: "SELECT * FROM goals WHERE workspace_id = ?1" },
  {
    name: "chat_messages",
    sql: "SELECT cm.* FROM chat_messages cm JOIN chats c ON c.id = cm.chat_id WHERE c.workspace_id = ?1",
  },
  { name: "runs", sql: "SELECT * FROM runs WHERE workspace_id = ?1" },
  {
    name: "phases",
    sql: "SELECT ph.* FROM phases ph JOIN runs r ON r.id = ph.run_id WHERE r.workspace_id = ?1",
  },
  {
    name: "tasks",
    sql: "SELECT t.* FROM tasks t JOIN phases ph ON ph.id = t.phase_id JOIN runs r ON r.id = ph.run_id WHERE r.workspace_id = ?1",
  },
  {
    name: "task_dependencies",
    sql: "SELECT td.* FROM task_dependencies td JOIN tasks t ON t.id = td.task_id JOIN phases ph ON ph.id = t.phase_id JOIN runs r ON r.id = ph.run_id WHERE r.workspace_id = ?1",
  },
  { name: "agents", sql: "SELECT * FROM agents WHERE workspace_id = ?1" },
  {
    name: "agent_enrollments",
    sql: "SELECT * FROM agent_enrollments WHERE workspace_id = ?1",
  },
  {
    name: "agent_sessions",
    sql: "SELECT * FROM agent_sessions WHERE workspace_id = ?1",
  },
  { name: "workers", sql: "SELECT * FROM workers WHERE workspace_id = ?1" },
  {
    name: "attempts",
    sql: "SELECT a.* FROM attempts a JOIN tasks t ON t.id = a.task_id JOIN phases ph ON ph.id = t.phase_id JOIN runs r ON r.id = ph.run_id WHERE r.workspace_id = ?1",
  },
  {
    name: "worker_assignments",
    sql: "SELECT * FROM worker_assignments WHERE workspace_id = ?1",
  },
  {
    name: "completion_criteria",
    sql: "SELECT cc.* FROM completion_criteria cc JOIN goals g ON g.id = cc.goal_id WHERE g.workspace_id = ?1",
  },
  {
    name: "verifications",
    sql: "SELECT * FROM verifications WHERE workspace_id = ?1",
  },
  { name: "artifacts", sql: "SELECT * FROM artifacts WHERE workspace_id = ?1" },
  { name: "findings", sql: "SELECT * FROM findings WHERE workspace_id = ?1" },
  { name: "events", sql: "SELECT * FROM events WHERE workspace_id = ?1" },
  { name: "budgets", sql: "SELECT * FROM budgets WHERE workspace_id = ?1" },
  { name: "usage", sql: "SELECT * FROM usage WHERE workspace_id = ?1" },
  { name: "audit_log", sql: "SELECT * FROM audit_log WHERE workspace_id = ?1" },
  {
    name: "ci_evidence",
    sql: "SELECT * FROM ci_evidence WHERE workspace_id = ?1",
  },
  {
    name: "persistence_records",
    sql: "SELECT * FROM persistence_records WHERE organization_id = ?1",
  },
];

function encodeBase64(bytes: Uint8Array): string {
  let value = "";
  for (const byte of bytes) value += String.fromCharCode(byte);
  return btoa(value);
}

function decodeBase64(value: string): Uint8Array {
  const decoded = atob(value);
  return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
}

async function workspaceBackupKey(
  secret: string,
  workspaceId: string,
): Promise<CryptoKey> {
  const keyMaterial = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${secret}:${workspaceId}`),
  );
  return await crypto.subtle.importKey(
    "raw",
    keyMaterial,
    { name: "AES-GCM" },
    false,
    ["decrypt"],
  );
}

async function createEncryptedWorkspaceBackup(
  env: SecurityEnv,
  workspaceId: string,
): Promise<{ key: string; digest: string; sizeBytes: number }> {
  const secret = env.CONCLAVE_SECURITY_KEY;
  const bucket = env.CONCLAVE_ARTIFACTS;
  if (!secret || !bucket) {
    throw new HttpError(503, "Encrypted backup storage is not configured");
  }
  const tables: Record<string, unknown[]> = {};
  for (const query of WORKSPACE_BACKUP_QUERIES) {
    const result = await env.CONCLAVE_DB.prepare(query.sql)
      .bind(workspaceId)
      .all<Record<string, unknown>>();
    tables[query.name] = result.results ?? [];
  }
  const plaintext = JSON.stringify({
    format: "conclave-workspace-backup-p1",
    workspaceId,
    exportedAt: new Date().toISOString(),
    tables,
  });
  const digest = await computePackageDigest(plaintext);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const keyMaterial = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${secret}:${workspaceId}`),
  );
  const key = await crypto.subtle.importKey(
    "raw",
    keyMaterial,
    { name: "AES-GCM" },
    false,
    ["encrypt"],
  );
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    new TextEncoder().encode(plaintext),
  );
  const envelope = JSON.stringify({
    format: "conclave-encrypted-backup-v1",
    workspaceId,
    digest,
    algorithm: "AES-GCM",
    keyDerivation: "SHA-256(secret:workspaceId)",
    iv: encodeBase64(iv),
    ciphertext: encodeBase64(new Uint8Array(ciphertext)),
  });
  const objectKey = `backups/${workspaceId}/${Date.now()}-${crypto.randomUUID()}.json`;
  await bucket.put(objectKey, envelope, {
    httpMetadata: { contentType: "application/json" },
    customMetadata: {
      workspaceId,
      digest,
      format: "conclave-encrypted-backup-v1",
    },
  });
  return { key: objectKey, digest, sizeBytes: envelope.length };
}

async function handleVerifyWorkspaceBackup(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await workspaceMemberContext(
    request,
    env,
    workspaceId,
    "audit:read",
    accessContext,
  );
  const bucket = env.CONCLAVE_ARTIFACTS;
  const secret = env.CONCLAVE_SECURITY_KEY;
  if (!bucket || !secret) {
    throw new HttpError(503, "Encrypted backup storage is not configured");
  }
  const body = (await request.json()) as Record<string, unknown>;
  const storageKey = requiredString(body.storageKey, "storageKey");
  const expectedPrefix = `backups/${workspaceId}/`;
  if (!storageKey.startsWith(expectedPrefix)) {
    throw new HttpError(404, "Backup not found");
  }
  const object = await bucket.get(storageKey);
  if (!object) throw new HttpError(404, "Backup not found");
  let envelope: Record<string, unknown>;
  try {
    envelope = JSON.parse(await object.text()) as Record<string, unknown>;
  } catch {
    throw new HttpError(422, "Backup envelope is invalid");
  }
  if (
    envelope.format !== "conclave-encrypted-backup-v1" ||
    envelope.workspaceId !== workspaceId ||
    envelope.algorithm !== "AES-GCM" ||
    typeof envelope.digest !== "string" ||
    typeof envelope.iv !== "string" ||
    typeof envelope.ciphertext !== "string"
  ) {
    throw new HttpError(422, "Backup envelope does not match this workspace");
  }
  let payload: Record<string, unknown>;
  try {
    const plaintext = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: decodeBase64(envelope.iv) as BufferSource },
      await workspaceBackupKey(secret, workspaceId),
      decodeBase64(envelope.ciphertext) as BufferSource,
    );
    payload = JSON.parse(new TextDecoder().decode(plaintext)) as Record<
      string,
      unknown
    >;
  } catch {
    throw new HttpError(422, "Backup decryption failed");
  }
  if (
    payload.format !== "conclave-workspace-backup-p1" ||
    payload.workspaceId !== workspaceId ||
    typeof payload.tables !== "object" ||
    payload.tables === null
  ) {
    throw new HttpError(422, "Backup payload is invalid");
  }
  const payloadText = JSON.stringify(payload);
  const digest = await computePackageDigest(payloadText);
  if (digest !== envelope.digest) {
    throw new HttpError(422, "Backup digest mismatch");
  }
  const tables = payload.tables as Record<string, unknown>;
  const tableCounts = Object.fromEntries(
    Object.entries(tables).map(([name, rows]) => [
      name,
      Array.isArray(rows) ? rows.length : 0,
    ]),
  );
  await recordAudit(
    env,
    context,
    "workspace.backup.restore_verified",
    "workspace",
    workspaceId,
    { digest, storageKey, tableCounts },
  );
  return json({
    format: "conclave-backup-restore-drill-v1",
    workspaceId,
    storageKey,
    digest,
    tableCounts,
    validatedAt: new Date().toISOString(),
  });
}

async function handleCreateWorkspaceBackup(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await workspaceMemberContext(
    request,
    env,
    workspaceId,
    "audit:read",
    accessContext,
  );
  const backup = await createEncryptedWorkspaceBackup(env, workspaceId);
  await recordAudit(
    env,
    context,
    "workspace.backup.exported",
    "workspace",
    workspaceId,
    {
      digest: backup.digest,
      storageKey: backup.key,
      sizeBytes: backup.sizeBytes,
    },
  );
  return json(
    {
      format: "conclave-encrypted-backup-v1",
      workspaceId,
      storageKey: backup.key,
      digest: backup.digest,
      sizeBytes: backup.sizeBytes,
    },
    { status: 201 },
  );
}

type CollaboratorRole = "admin" | "member" | "viewer";

async function workspaceMemberContext(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  permission: Permission,
  accessContext?: ExecutionContext,
): Promise<SecurityContext> {
  const context = await securityContext(request, env, accessContext);
  if (!anonymousDevelopment(env) && context.workspaceId !== workspaceId) {
    throw new HttpError(404, "Workspace not found");
  }
  try {
    authorize(context, permission, workspaceId);
  } catch (error) {
    throw new HttpError(
      403,
      error instanceof Error ? error.message : "Forbidden",
    );
  }
  return context;
}

async function handleCreateWorkspaceInvitation(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await workspaceMemberContext(
    request,
    env,
    workspaceId,
    "members:manage",
    accessContext,
  );
  const body = (await request.json()) as Record<string, unknown>;
  const email = requiredString(body.email, "email").trim().toLowerCase();
  if (!/^\S+@\S+\.\S+$/.test(email))
    throw new HttpError(400, "email must be a valid email address");
  const role = (
    typeof body.role === "string" ? body.role : "member"
  ) as CollaboratorRole;
  if (role !== "admin" && role !== "member" && role !== "viewer")
    throw new HttpError(400, "role must be admin, member, or viewer");
  const expiresInHours =
    typeof body.expiresInHours === "number" && body.expiresInHours > 0
      ? Math.min(body.expiresInHours, 24 * 30)
      : 72;
  const projectId = typeof body.projectId === "string" ? body.projectId : null;
  if (projectId) {
    const project = await env.CONCLAVE_DB.prepare(
      "SELECT id FROM projects WHERE id = ?1 AND workspace_id = ?2",
    )
      .bind(projectId, workspaceId)
      .first<{ id: string }>();
    if (!project) throw new HttpError(404, "Project not found in workspace");
  }
  const now = new Date();
  const expiresAt = new Date(
    now.getTime() + expiresInHours * 3600000,
  ).toISOString();
  const token = `invite_${crypto.randomUUID()}_${crypto.randomUUID()}`;
  const id = `inv-${crypto.randomUUID()}`;
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO workspace_invitations
       (id, workspace_id, project_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'pending', ?8, ?9, ?9)`,
  )
    .bind(
      id,
      workspaceId,
      projectId,
      email,
      role,
      await hashToken(token),
      context.userId,
      expiresAt,
      now.toISOString(),
    )
    .run();
  await recordAudit(
    env,
    context,
    "workspace.invitation.created",
    "invitation",
    id,
    {
      email,
      role,
      projectId,
      expiresAt,
    },
  );
  return json(
    {
      invitation: {
        id,
        workspaceId,
        projectId,
        email,
        role,
        status: "pending",
        expiresAt,
      },
      // The token is returned once so an email/notification adapter can deliver it.
      token,
    },
    { status: 201 },
  );
}

async function handleListWorkspaceInvitations(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await workspaceMemberContext(
    request,
    env,
    workspaceId,
    "members:manage",
    accessContext,
  );
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, workspace_id AS workspaceId, project_id AS projectId, email, role, status, expires_at AS expiresAt,
            invited_by_user_id AS invitedByUserId, accepted_by_user_id AS acceptedByUserId,
            accepted_at AS acceptedAt, created_at AS createdAt, updated_at AS updatedAt
     FROM workspace_invitations WHERE workspace_id = ?1 ORDER BY created_at DESC`,
  )
    .bind(workspaceId)
    .all();
  return json({ invitations: rows.results ?? [] });
}

async function handleAcceptWorkspaceInvitation(
  request: Request,
  env: SecurityEnv,
  token: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  if (!context.userId) throw new HttpError(401, "Authentication required");
  const tokenHash = await hashToken(token);
  const invitation = await env.CONCLAVE_DB.prepare(
    `SELECT id, workspace_id AS workspaceId, project_id AS projectId, email, role, status, expires_at AS expiresAt
     FROM workspace_invitations WHERE token_hash = ?1`,
  )
    .bind(tokenHash)
    .first<{
      id: string;
      workspaceId: string;
      projectId: string | null;
      email: string;
      role: CollaboratorRole;
      status: string;
      expiresAt: string;
    }>();
  if (!invitation) throw new HttpError(404, "Invitation not found");
  if (invitation.status !== "pending")
    throw new HttpError(409, "Invitation is no longer pending");
  if (new Date(invitation.expiresAt).getTime() <= Date.now()) {
    await env.CONCLAVE_DB.prepare(
      "UPDATE workspace_invitations SET status = 'expired', updated_at = ?1 WHERE id = ?2 AND status = 'pending'",
    )
      .bind(new Date().toISOString(), invitation.id)
      .run();
    throw new HttpError(410, "Invitation has expired");
  }
  if (context.user.email.toLowerCase() !== invitation.email.toLowerCase())
    throw new HttpError(
      403,
      "Invitation email does not match the authenticated user",
    );
  const now = new Date().toISOString();
  const membershipStatements = [
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_memberships (id, workspace_id, user_id, role, status, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, 'active', ?5, ?5)
       ON CONFLICT(workspace_id, user_id) DO UPDATE SET role = excluded.role, status = 'active', updated_at = excluded.updated_at`,
    ).bind(
      `wm-${crypto.randomUUID()}`,
      invitation.workspaceId,
      context.userId,
      invitation.role,
      now,
    ),
    env.CONCLAVE_DB.prepare(
      `UPDATE workspace_invitations SET status = 'accepted', accepted_by_user_id = ?1, accepted_at = ?2, updated_at = ?2 WHERE id = ?3 AND status = 'pending'`,
    ).bind(context.userId, now, invitation.id),
  ];
  if (invitation.projectId) {
    membershipStatements.push(
      env.CONCLAVE_DB.prepare(
        `INSERT INTO project_memberships (id, project_id, user_id, role, created_at, updated_at)
         VALUES (?1, ?2, ?3, 'collaborator', ?4, ?4)
         ON CONFLICT(project_id, user_id) DO UPDATE SET role = 'collaborator', updated_at = excluded.updated_at`,
      ).bind(
        `pm-${crypto.randomUUID()}`,
        invitation.projectId,
        context.userId,
        now,
      ),
    );
  }
  await env.CONCLAVE_DB.batch(membershipStatements);
  const acceptedContext = { ...context, workspaceId: invitation.workspaceId };
  await recordAudit(
    env,
    acceptedContext,
    "workspace.invitation.accepted",
    "invitation",
    invitation.id,
    {
      userId: context.userId,
      role: invitation.role,
    },
  );
  return json({
    workspaceId: invitation.workspaceId,
    projectId: invitation.projectId,
    membership: {
      userId: context.userId,
      role: invitation.role,
      status: "active",
    },
  });
}

async function handleExpireWorkspaceInvitation(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  invitationId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await workspaceMemberContext(
    request,
    env,
    workspaceId,
    "members:manage",
    accessContext,
  );
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE workspace_invitations SET status = 'expired', updated_at = ?1
     WHERE id = ?2 AND workspace_id = ?3 AND status = 'pending'`,
  )
    .bind(new Date().toISOString(), invitationId, workspaceId)
    .run();
  if (!result.success) throw new HttpError(404, "Pending invitation not found");
  await recordAudit(
    env,
    context,
    "workspace.invitation.expired",
    "invitation",
    invitationId,
  );
  return json({ id: invitationId, status: "expired" });
}

async function handleChangeWorkspaceMemberRole(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  userId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await workspaceMemberContext(
    request,
    env,
    workspaceId,
    "members:manage",
    accessContext,
  );
  const body = (await request.json()) as Record<string, unknown>;
  const role = body.role;
  if (role !== "admin" && role !== "member" && role !== "viewer")
    throw new HttpError(400, "role must be admin, member, or viewer");
  const result = await env.CONCLAVE_DB.prepare(
    "UPDATE workspace_memberships SET role = ?1, updated_at = ?2 WHERE workspace_id = ?3 AND user_id = ?4 AND role <> 'owner'",
  )
    .bind(role, new Date().toISOString(), workspaceId, userId)
    .run();
  if (!result.success)
    throw new HttpError(404, "Member not found or owner role cannot change");
  await recordAudit(
    env,
    context,
    "workspace.member.role_changed",
    "user",
    userId,
    { role },
  );
  return json({ workspaceId, userId, role });
}

async function handleWorkspaceMemberStatus(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  userId: string,
  status: "active" | "suspended" | "removed",
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await workspaceMemberContext(
    request,
    env,
    workspaceId,
    "members:manage",
    accessContext,
  );
  if (status === "removed") {
    const result = await env.CONCLAVE_DB.prepare(
      "DELETE FROM workspace_memberships WHERE workspace_id = ?1 AND user_id = ?2 AND role <> 'owner'",
    )
      .bind(workspaceId, userId)
      .run();
    if (!result.success)
      throw new HttpError(404, "Member not found or owner cannot be removed");
  } else {
    const result = await env.CONCLAVE_DB.prepare(
      "UPDATE workspace_memberships SET status = ?1, updated_at = ?2 WHERE workspace_id = ?3 AND user_id = ?4 AND role <> 'owner'",
    )
      .bind(status, new Date().toISOString(), workspaceId, userId)
      .run();
    if (!result.success)
      throw new HttpError(
        404,
        "Member not found or owner status cannot change",
      );
  }
  await recordAudit(env, context, `workspace.member.${status}`, "user", userId);
  return json({ workspaceId, userId, status });
}

// =========================================================================
// Projects API Handlers
// =========================================================================

async function handleListProjects(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    securityEnv(env),
    "projects:read",
    undefined,
    accessContext,
  );
  const isOwnerOrAdmin =
    context.workspaceRole === "owner" ||
    context.workspaceRole === "admin" ||
    anonymousDevelopment(env);
  const rows = isOwnerOrAdmin
    ? await env.CONCLAVE_DB.prepare(
        `SELECT p.id, p.workspace_id AS workspaceId, p.name, p.description, p.repository_id AS repositoryId,
                p.settings_json AS settingsJson, p.created_at AS createdAt, p.updated_at AS updatedAt
         FROM projects p WHERE p.workspace_id = ?1 ORDER BY p.updated_at DESC`,
      )
        .bind(context.workspaceId)
        .all<{
          id: string;
          workspaceId: string;
          name: string;
          description: string | null;
          repositoryId: string | null;
          settingsJson: string;
          createdAt: string;
          updatedAt: string;
        }>()
    : await env.CONCLAVE_DB.prepare(
        `SELECT p.id, p.workspace_id AS workspaceId, p.name, p.description, p.repository_id AS repositoryId,
                p.settings_json AS settingsJson, p.created_at AS createdAt, p.updated_at AS updatedAt
         FROM projects p
         JOIN project_memberships pm ON pm.project_id = p.id
         WHERE p.workspace_id = ?1 AND pm.user_id = ?2
         ORDER BY p.updated_at DESC`,
      )
        .bind(context.workspaceId, context.userId)
        .all<{
          id: string;
          workspaceId: string;
          name: string;
          description: string | null;
          repositoryId: string | null;
          settingsJson: string;
          createdAt: string;
          updatedAt: string;
        }>();

  const projects = (rows.results ?? []).map((row) => ({
    id: row.id,
    workspaceId: row.workspaceId,
    name: row.name,
    description: row.description,
    repositoryId: row.repositoryId,
    settings: parseJson(row.settingsJson),
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  }));
  return json({ projects });
}

function securityEnv(env: Env): SecurityEnv {
  return env as SecurityEnv;
}

async function handleCreateProject(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "projects:manage",
    undefined,
    accessContext,
  );
  const body = (await request.json()) as Record<string, unknown>;
  const name = requiredString(body.name, "name");
  const description =
    typeof body.description === "string" ? body.description : null;
  const repositoryId =
    typeof body.repositoryId === "string" ? body.repositoryId : null;
  const settings =
    typeof body.settings === "object" && body.settings !== null
      ? (body.settings as Record<string, unknown>)
      : {};
  const now = new Date().toISOString();
  const id = `proj-${crypto.randomUUID()}`;

  const project: Project = {
    id,
    workspaceId: context.workspaceId,
    name,
    description,
    repositoryId,
    settings,
    createdAt: now,
    updatedAt: now,
  };
  validateProject(project);

  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `INSERT INTO projects (id, workspace_id, name, description, repository_id, settings_json, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)`,
    ).bind(
      id,
      context.workspaceId,
      name,
      description,
      repositoryId,
      JSON.stringify(settings),
      now,
    ),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO project_memberships (id, project_id, user_id, role, created_at, updated_at)
       VALUES (?1, ?2, ?3, 'lead', ?4, ?4)
       ON CONFLICT(project_id, user_id) DO NOTHING`,
    ).bind(`pm-${crypto.randomUUID()}`, id, context.userId, now),
  ]);

  return json({ project }, { status: 201 });
}

async function handleGetProject(
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
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT p.id, p.workspace_id AS workspaceId, p.name, p.description, p.repository_id AS repositoryId,
            p.settings_json AS settingsJson, p.created_at AS createdAt, p.updated_at AS updatedAt
     FROM projects p WHERE p.id = ?1 AND p.workspace_id = ?2`,
  )
    .bind(projectId, context.workspaceId)
    .first<{
      id: string;
      workspaceId: string;
      name: string;
      description: string | null;
      repositoryId: string | null;
      settingsJson: string;
      createdAt: string;
      updatedAt: string;
    }>();
  if (!row) throw new HttpError(404, "Project not found");
  return json({
    project: {
      id: row.id,
      workspaceId: row.workspaceId,
      name: row.name,
      description: row.description,
      repositoryId: row.repositoryId,
      settings: parseJson(row.settingsJson),
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    },
  });
}

// =========================================================================
// Chats & Chat Messages API Handlers
// =========================================================================

async function handleListChats(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "chats:read",
    projectId,
    accessContext,
  );
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, project_id AS projectId, workspace_id AS workspaceId, created_by_user_id AS createdByUserId,
            title, status, created_at AS createdAt, updated_at AS updatedAt
     FROM chats
     WHERE project_id = ?1 AND (workspace_id = ?2 OR workspace_id IS NULL)
     ORDER BY updated_at DESC`,
  )
    .bind(projectId, context.workspaceId)
    .all<{
      id: string;
      projectId: string;
      workspaceId: string;
      createdByUserId: string;
      title: string;
      status: import("@conclave/core").ChatStatus;
      createdAt: string;
      updatedAt: string;
    }>();
  return json({ chats: rows.results ?? [] });
}

async function handleCreateChat(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "chats:create",
    projectId,
    accessContext,
  );
  const body = (await request.json()) as Record<string, unknown>;
  const title = requiredString(body.title, "title");
  const now = new Date().toISOString();
  const id = `chat-${crypto.randomUUID()}`;

  const chat: Chat = {
    id,
    projectId,
    workspaceId: context.workspaceId,
    createdByUserId: context.userId,
    title,
    status: "active",
    createdAt: now,
    updatedAt: now,
  };
  validateChat(chat);

  await env.CONCLAVE_DB.prepare(
    `INSERT INTO chats (id, project_id, workspace_id, created_by_user_id, title, status, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, 'active', ?6, ?6)`,
  )
    .bind(id, projectId, context.workspaceId, context.userId, title, now)
    .run();

  return json({ chat }, { status: 201 });
}

async function handleGetChat(
  request: Request,
  env: SecurityEnv,
  chatId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const chatRow = await env.CONCLAVE_DB.prepare(
    `SELECT id, project_id AS projectId, workspace_id AS workspaceId, created_by_user_id AS createdByUserId,
            title, status, created_at AS createdAt, updated_at AS updatedAt
     FROM chats WHERE id = ?1`,
  )
    .bind(chatId)
    .first<{
      id: string;
      projectId: string;
      workspaceId: string;
      createdByUserId: string;
      title: string;
      status: import("@conclave/core").ChatStatus;
      createdAt: string;
      updatedAt: string;
    }>();
  if (!chatRow) throw new HttpError(404, "Chat not found");

  await authorizeRequest(
    request,
    env,
    "chats:read",
    chatRow.projectId,
    accessContext,
  );
  return json({ chat: chatRow });
}

async function handleUpdateChat(
  request: Request,
  env: SecurityEnv,
  chatId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const chatRow = await env.CONCLAVE_DB.prepare(
    `SELECT id, project_id AS projectId, workspace_id AS workspaceId, created_by_user_id AS createdByUserId,
            title, status, created_at AS createdAt, updated_at AS updatedAt
     FROM chats WHERE id = ?1`,
  )
    .bind(chatId)
    .first<{
      id: string;
      projectId: string;
      workspaceId: string;
      createdByUserId: string;
      title: string;
      status: import("@conclave/core").ChatStatus;
      createdAt: string;
      updatedAt: string;
    }>();
  if (!chatRow) throw new HttpError(404, "Chat not found");

  await authorizeRequest(
    request,
    env,
    "chats:create",
    chatRow.projectId,
    accessContext,
  );
  const body = (await request.json()) as Record<string, unknown>;
  const title =
    typeof body.title === "string" && body.title.trim().length > 0
      ? body.title.trim()
      : chatRow.title;
  const status =
    body.status === "archived"
      ? "archived"
      : body.status === "active"
        ? "active"
        : chatRow.status;
  const now = new Date().toISOString();

  await env.CONCLAVE_DB.prepare(
    "UPDATE chats SET title = ?1, status = ?2, updated_at = ?3 WHERE id = ?4",
  )
    .bind(title, status, now, chatId)
    .run();

  return json({
    chat: {
      ...chatRow,
      title,
      status,
      updatedAt: now,
    },
  });
}

async function handleListChatGoals(
  request: Request,
  env: SecurityEnv,
  chatId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const chatRow = await env.CONCLAVE_DB.prepare(
    "SELECT id, project_id AS projectId, workspace_id AS workspaceId FROM chats WHERE id = ?1",
  )
    .bind(chatId)
    .first<{ id: string; projectId: string; workspaceId: string }>();
  if (!chatRow) throw new HttpError(404, "Chat not found");

  await authorizeRequest(
    request,
    env,
    "chats:read",
    chatRow.projectId,
    accessContext,
  );
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, workspace_id AS workspaceId, project_id AS projectId, chat_id AS chatId,
            created_by_user_id AS createdByUserId, original_message AS originalMessage,
            objective, status, created_at AS createdAt, updated_at AS updatedAt
     FROM goals WHERE chat_id = ?1 ORDER BY created_at ASC`,
  )
    .bind(chatId)
    .all();
  return json({ goals: rows.results ?? [] });
}

async function handleListChatMessages(
  request: Request,
  env: SecurityEnv,
  chatId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const chatRow = await env.CONCLAVE_DB.prepare(
    "SELECT id, project_id AS projectId, workspace_id AS workspaceId FROM chats WHERE id = ?1",
  )
    .bind(chatId)
    .first<{ id: string; projectId: string; workspaceId: string }>();
  if (!chatRow) throw new HttpError(404, "Chat not found");

  await authorizeRequest(
    request,
    env,
    "chats:read",
    chatRow.projectId,
    accessContext,
  );
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, chat_id AS chatId, sender_type AS senderType, sender_id AS senderId,
            content, kind, goal_id AS goalId, metadata_json AS metadataJson, created_at AS createdAt
     FROM chat_messages WHERE chat_id = ?1 ORDER BY created_at ASC`,
  )
    .bind(chatId)
    .all<{
      id: string;
      chatId: string;
      senderType: ChatMessageSenderType;
      senderId: string;
      content: string;
      kind: ChatMessageKind;
      goalId: string | null;
      metadataJson: string;
      createdAt: string;
    }>();

  const messages = (rows.results ?? []).map((row) => ({
    id: row.id,
    chatId: row.chatId,
    senderType: row.senderType,
    senderId: row.senderId,
    content: row.content,
    kind: row.kind,
    goalId: row.goalId ?? null,
    metadata: parseJson(row.metadataJson),
    createdAt: row.createdAt,
  }));
  return json({ messages });
}

async function handleCreateChatMessage(
  request: Request,
  env: SecurityEnv,
  chatId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const chatRow = await env.CONCLAVE_DB.prepare(
    "SELECT id, project_id AS projectId, workspace_id AS workspaceId FROM chats WHERE id = ?1",
  )
    .bind(chatId)
    .first<{ id: string; projectId: string; workspaceId: string }>();
  if (!chatRow) throw new HttpError(404, "Chat not found");

  const context = await authorizeRequest(
    request,
    env,
    "chats:create",
    chatRow.projectId,
    accessContext,
  );
  const body = (await request.json()) as Record<string, unknown>;
  const content = requiredString(body.content, "content");
  const senderType = (
    typeof body.senderType === "string" ? body.senderType : "user"
  ) as ChatMessageSenderType;
  const senderId =
    typeof body.senderId === "string" ? body.senderId : context.userId;
  const kind = (
    typeof body.kind === "string" ? body.kind : "user"
  ) as ChatMessageKind;
  const goalId = typeof body.goalId === "string" ? body.goalId : null;
  const metadata =
    typeof body.metadata === "object" && body.metadata !== null
      ? (body.metadata as Record<string, unknown>)
      : {};

  // Intent is a proposal boundary, not an orchestration command. Core decides
  // whether a referenced Goal is legal to continue, approve, or follow up.
  const goalRows = await env.CONCLAVE_DB.prepare(
    `SELECT id, status FROM goals WHERE chat_id = ?1 ORDER BY updated_at DESC`,
  )
    .bind(chatId)
    .all<{ id: string; status: import("@conclave/core").ChatGoalStatus }>();
  const intentProposal =
    body.intentProposal !== undefined
      ? parseChatIntentProposal(body.intentProposal)
      : recommendChatIntent(content, {
          goals: (goalRows.results ?? []).map((goal) => ({
            id: goal.id,
            status: goal.status,
            awaitingUserInput: goal.status === "waiting",
          })),
        });
  const intentDecision = decideChatIntent(intentProposal, {
    goals: (goalRows.results ?? []).map((goal) => ({
      id: goal.id,
      status: goal.status,
      awaitingUserInput: goal.status === "waiting",
    })),
  });
  const projectRow = await env.CONCLAVE_DB.prepare(
    "SELECT settings_json AS settingsJson FROM projects WHERE id = ?1",
  )
    .bind(chatRow.projectId)
    .first<{ settingsJson: string }>();
  const projectSettings = parseJson<Record<string, unknown>>(
    projectRow?.settingsJson,
  );
  const projectInstructions =
    typeof projectSettings.instructions === "string" &&
    projectSettings.instructions.trim().length > 0
      ? [
          {
            id: `project-instructions:${chatRow.projectId}`,
            kind: "project_instruction" as const,
            content: projectSettings.instructions,
            sourceId: chatRow.projectId,
          },
        ]
      : [];
  const explicitReferences = Array.isArray(body.references)
    ? body.references.flatMap((reference) => {
        if (typeof reference === "string" && reference.trim().length > 0) {
          return [
            {
              id: `explicit-reference:${reference}`,
              kind: "explicit_reference" as const,
              content: reference,
              sourceId: reference,
            },
          ];
        }
        if (
          reference &&
          typeof reference === "object" &&
          typeof (reference as Record<string, unknown>).id === "string" &&
          typeof (reference as Record<string, unknown>).content === "string"
        ) {
          const value = reference as { id: string; content: string };
          return [
            {
              id: `explicit-reference:${value.id}`,
              kind: "explicit_reference" as const,
              content: value.content,
              sourceId: value.id,
            },
          ];
        }
        return [];
      })
    : [];
  const contextItems = assembleChatContext({
    currentMessage: content,
    projectInstructions,
    explicitReferences,
  });
  const messageMetadata = {
    ...metadata,
    intent: {
      proposal: intentProposal,
      decision: intentDecision,
    },
    contextSelection: {
      itemIds: contextItems.map((item) => item.id),
      itemKinds: contextItems.map((item) => item.kind),
      transcriptIncluded: false,
    },
  };
  const now = new Date().toISOString();
  const id = `msg-${crypto.randomUUID()}`;

  const message: ChatMessage = {
    id,
    chatId,
    senderType,
    senderId,
    content,
    kind,
    goalId,
    metadata: messageMetadata,
    createdAt: now,
  };
  validateChatMessage(message);

  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `INSERT INTO chat_messages (id, chat_id, sender_type, sender_id, content, kind, goal_id, metadata_json, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)`,
    ).bind(
      id,
      chatId,
      senderType,
      senderId,
      content,
      kind,
      goalId,
      JSON.stringify(messageMetadata),
      now,
    ),
    env.CONCLAVE_DB.prepare(
      "UPDATE chats SET updated_at = ?1 WHERE id = ?2",
    ).bind(now, chatId),
  ]);

  return json(
    {
      message,
      intent: intentDecision,
      context: contextItems.map((item) => ({
        id: item.id,
        kind: item.kind,
        sourceId: item.sourceId ?? null,
      })),
    },
    { status: 201 },
  );
}

// =========================================================================
// Agent Enrollment & Fleet Handlers
// =========================================================================

async function handleCreateAgentEnrollment(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "agents:manage");
  requireWorkspaceContext(context, env, workspaceId);

  const body = parseJson<{ expiresHours?: number; maxUses?: number }>(
    await request.text(),
    {},
  );
  const enrollmentId = `enr-${crypto.randomUUID().slice(0, 12)}`;
  const token = `conclave_enroll_${crypto.randomUUID().replace(/-/g, "")}`;
  const tokenHash = await hashToken(token);
  const now = new Date();
  const expiresHours = body.expiresHours ?? 24;
  const expiresAt = new Date(
    now.getTime() + expiresHours * 3600 * 1000,
  ).toISOString();
  const createdAt = now.toISOString();

  await env.CONCLAVE_DB.prepare(
    `INSERT INTO agent_enrollments (id, workspace_id, token_hash, created_by_user_id, expires_at, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
  )
    .bind(
      enrollmentId,
      workspaceId,
      tokenHash,
      context.userId,
      expiresAt,
      createdAt,
    )
    .run();

  await recordAudit(
    env,
    context,
    "agent.enrollment.created",
    "agent_enrollment",
    enrollmentId,
    { expiresAt, maxUses: body.maxUses ?? null },
  );

  return json(
    {
      id: enrollmentId,
      token,
      workspaceId,
      expiresAt,
      createdAt,
    },
    { status: 201 },
  );
}

async function handleListAgentEnrollments(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "agents:read");
  requireWorkspaceContext(context, env, workspaceId);

  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, workspace_id as workspaceId, created_by_user_id as createdByUserId, expires_at as expiresAt, used_at as usedAt, revoked_at as revokedAt, created_at as createdAt
     FROM agent_enrollments WHERE workspace_id = ?1 ORDER BY created_at DESC`,
  )
    .bind(workspaceId)
    .all();

  return json({ enrollments: rows.results ?? [] });
}

async function handleRevokeAgentEnrollment(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  enrollmentId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "agents:manage");
  requireWorkspaceContext(context, env, workspaceId);

  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `UPDATE agent_enrollments SET revoked_at = ?1 WHERE id = ?2 AND workspace_id = ?3`,
  )
    .bind(now, enrollmentId, workspaceId)
    .run();

  await recordAudit(
    env,
    context,
    "agent.enrollment.revoked",
    "agent_enrollment",
    enrollmentId,
  );

  return json({ ok: true, revokedAt: now });
}

async function handleEnrollAgent(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const body = parseJson<{
    token?: string;
    name?: string;
    hostname?: string;
    agentId?: string;
  }>(await request.text(), {});

  if (!body.token) {
    return json({ error: "Enrollment token is required" }, { status: 400 });
  }

  const tokenHash = await hashToken(body.token);
  const now = new Date().toISOString();

  const enrollment = await env.CONCLAVE_DB.prepare(
    `SELECT * FROM agent_enrollments WHERE token_hash = ?1 AND revoked_at IS NULL AND expires_at > ?2`,
  )
    .bind(tokenHash, now)
    .first<{
      id: string;
      workspace_id: string;
      created_by_user_id: string;
    }>();

  if (!enrollment) {
    return json(
      { error: "Invalid, expired, or revoked enrollment token" },
      { status: 401 },
    );
  }

  const agentId = body.agentId || `agent-${crypto.randomUUID().slice(0, 8)}`;
  const authToken = `conclave_agent_tok_${crypto.randomUUID().replace(/-/g, "")}`;
  const authTokenHash = await hashToken(authToken);

  await env.CONCLAVE_DB.prepare(
    `INSERT INTO agents (id, workspace_id, name, hostname, status, version, capabilities_json, auth_token_hash, enrolled_at, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, 'enrolled', '0.2.0', '{}', ?5, ?6, ?6, ?6)
     ON CONFLICT(id) DO UPDATE SET
       auth_token_hash = excluded.auth_token_hash,
       status = 'enrolled',
       updated_at = excluded.updated_at`,
  )
    .bind(
      agentId,
      enrollment.workspace_id,
      body.name || `Agent ${agentId}`,
      body.hostname || "localhost",
      authTokenHash,
      now,
    )
    .run();

  await env.CONCLAVE_DB.prepare(
    `UPDATE agent_enrollments SET used_at = ?1 WHERE id = ?2`,
  )
    .bind(now, enrollment.id)
    .run();

  return json(
    {
      agentId,
      workspaceId: enrollment.workspace_id,
      authToken,
    },
    { status: 201 },
  );
}

async function handleListAgents(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "agents:read");
  requireWorkspaceContext(context, env, workspaceId);

  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, workspace_id as workspaceId, name, hostname, status, version, capabilities_json as capabilitiesJson, enrolled_at as enrolledAt, last_heartbeat_at as lastHeartbeatAt, revoked_at as revokedAt, created_at as createdAt, updated_at as updatedAt
     FROM agents WHERE workspace_id = ?1 ORDER BY created_at DESC`,
  )
    .bind(workspaceId)
    .all();

  return json({ agents: rows.results ?? [] });
}

async function handleGetAgent(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  agentId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "agents:read");
  requireWorkspaceContext(context, env, workspaceId);

  const agent = await env.CONCLAVE_DB.prepare(
    `SELECT id, workspace_id as workspaceId, name, hostname, status, version, capabilities_json as capabilitiesJson, enrolled_at as enrolledAt, last_heartbeat_at as lastHeartbeatAt, revoked_at as revokedAt, created_at as createdAt, updated_at as updatedAt
     FROM agents WHERE workspace_id = ?1 AND id = ?2`,
  )
    .bind(workspaceId, agentId)
    .first();

  if (!agent) return json({ error: "Agent not found" }, { status: 404 });

  const sessions = await env.CONCLAVE_DB.prepare(
    `SELECT id, client_version as clientVersion, protocol_version as protocolVersion, connected_at as connectedAt, last_heartbeat_at as lastHeartbeatAt, disconnected_at as disconnectedAt
     FROM agent_sessions WHERE agent_id = ?1 ORDER BY connected_at DESC LIMIT 10`,
  )
    .bind(agentId)
    .all();

  return json({ agent, sessions: sessions.results ?? [] });
}

async function handleRevokeAgent(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  agentId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "agents:manage");
  requireWorkspaceContext(context, env, workspaceId);

  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `UPDATE agents SET status = 'revoked', revoked_at = ?1, updated_at = ?1 WHERE workspace_id = ?2 AND id = ?3`,
  )
    .bind(now, workspaceId, agentId)
    .run();

  await recordAudit(env, context, "agent.revoked", "agent", agentId, {
    revokedAt: now,
  });

  return json({ ok: true, revokedAt: now });
}

async function handleListWorkers(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "agents:read");
  requireWorkspaceContext(context, env, workspaceId);

  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, workspace_id as workspaceId, agent_id as agentId, plugin_id as pluginId,
            plugin_version_policy as pluginVersionPolicy, name, roles_json as rolesJson,
            capabilities_json as capabilitiesJson, config_json as configJson,
            secret_refs_json as secretRefsJson, billing_mode as billingMode,
            cost_metadata_json as costMetadataJson, independence_key as independenceKey,
            concurrency_limit as concurrencyLimit, session_policy as sessionPolicy,
            enabled, status, created_at as createdAt, updated_at as updatedAt
     FROM workers WHERE workspace_id = ?1 ORDER BY created_at DESC`,
  )
    .bind(workspaceId)
    .all<Record<string, unknown>>();

  const workers = (rows.results ?? []).map((row) => ({
    id: String(row.id),
    workspaceId: String(row.workspaceId),
    agentId: String(row.agentId),
    pluginId: String(row.pluginId),
    pluginVersionPolicy: String(row.pluginVersionPolicy),
    name: String(row.name),
    roles: parseJson(row.rolesJson, []),
    capabilities: parseJson(row.capabilitiesJson, []),
    config: parseJson(row.configJson, {}),
    secretRefs: parseJson(row.secretRefsJson, []),
    billingMode: String(row.billingMode),
    costMetadata: parseJson(row.costMetadataJson, {}),
    independenceKey: String(row.independenceKey),
    concurrencyLimit: Number(row.concurrencyLimit),
    sessionPolicy: String(row.sessionPolicy || "stateless"),
    enabled: Number(row.enabled) === 1,
    availability: String(row.status || "available"),
    createdAt: String(row.createdAt),
    updatedAt: String(row.updatedAt),
  }));

  return json({ workers });
}

async function handleCreateWorker(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "agents:manage");
  requireWorkspaceContext(context, env, workspaceId);

  const body = (await request.json()) as Record<string, unknown>;
  const now = new Date().toISOString();
  const id =
    typeof body.id === "string" && body.id.trim().length > 0
      ? body.id.trim()
      : `worker-${crypto.randomUUID()}`;
  const agentId = requiredString(body.agentId, "agentId");
  const pluginId = requiredString(body.pluginId, "pluginId");
  const pluginVersionPolicy =
    typeof body.pluginVersionPolicy === "string" &&
    body.pluginVersionPolicy.length > 0
      ? body.pluginVersionPolicy
      : "latest";
  const name = requiredString(body.name, "name");
  const roles =
    Array.isArray(body.roles) && body.roles.length > 0
      ? (body.roles as string[])
      : ["implementer"];
  const capabilities =
    Array.isArray(body.capabilities) && body.capabilities.length > 0
      ? (body.capabilities as string[])
      : ["code_execution"];
  const config = (
    typeof body.config === "object" && body.config !== null ? body.config : {}
  ) as Record<string, unknown>;
  const secretRefs = Array.isArray(body.secretRefs)
    ? (body.secretRefs as string[])
    : [];
  const billingMode = (
    typeof body.billingMode === "string" ? body.billingMode : "local_compute"
  ) as Worker["billingMode"];
  const costMetadata =
    typeof body.costMetadata === "object" && body.costMetadata !== null
      ? (body.costMetadata as WorkerCostMetadata)
      : undefined;
  const independenceKey =
    typeof body.independenceKey === "string" && body.independenceKey.length > 0
      ? body.independenceKey
      : id;
  const concurrencyLimit =
    typeof body.concurrencyLimit === "number" && body.concurrencyLimit >= 1
      ? Math.floor(body.concurrencyLimit)
      : 1;
  const sessionPolicy = (
    typeof body.sessionPolicy === "string" ? body.sessionPolicy : "stateless"
  ) as Worker["sessionPolicy"];
  const enabled = body.enabled !== false;
  const availability = (
    typeof body.availability === "string" ? body.availability : "available"
  ) as Worker["availability"];

  const worker: Worker = {
    id,
    workspaceId,
    agentId,
    pluginId,
    pluginVersionPolicy,
    name,
    roles,
    capabilities,
    config,
    secretRefs,
    enabled,
    availability,
    billingMode,
    costMetadata,
    independenceKey,
    concurrencyLimit,
    sessionPolicy,
    createdAt: now,
    updatedAt: now,
  };

  // Validate agent and plugin references
  const agentRow = await env.CONCLAVE_DB.prepare(
    `SELECT id, workspace_id as workspaceId, status
     FROM agents WHERE id = ?1 AND workspace_id = ?2`,
  )
    .bind(agentId, workspaceId)
    .first<{ id: string; workspaceId: string; status: string }>();

  if (!agentRow) {
    return json({ error: `Agent '${agentId}' not found` }, { status: 404 });
  }

  const pluginRow = await env.CONCLAVE_DB.prepare(
    `SELECT id, status FROM worker_plugins WHERE id = ?1`,
  )
    .bind(pluginId)
    .first<{ id: string; status: string }>();

  if (!pluginRow) {
    return json({ error: `Plugin '${pluginId}' not found` }, { status: 404 });
  }

  try {
    validateWorker(worker, {
      agent: {
        id: agentRow.id,
        workspaceId: agentRow.workspaceId,
        name: "agent",
        hostname: "agent.local",
        version: "2.0.0",
        status: agentRow.status as "online" | "offline" | "revoked",
        capabilities: {
          version: "2.0.0",
          os: "macos",
          arch: "arm64",
          supportedRuntimes: ["node"],
          maxConcurrentWorkers: 10,
        },
        enrolledAt: now,
        lastHeartbeatAt: now,
        revokedAt: null,
      },
      plugin: {
        id: pluginRow.id,
        displayName: pluginRow.id,
        description: "",
        publisher: "conclave",
        supportedRoles: roles,
        supportedCapabilities: capabilities,
        status: pluginRow.status as "active" | "deprecated" | "revoked",
      },
    });
  } catch (err) {
    return json(
      { error: err instanceof Error ? err.message : String(err) },
      { status: 400 },
    );
  }

  await env.CONCLAVE_DB.prepare(
    `INSERT INTO workers (
       id, workspace_id, agent_id, plugin_id, plugin_version_policy,
       name, roles_json, capabilities_json, config_json, secret_refs_json,
       billing_mode, cost_metadata_json, independence_key, concurrency_limit,
       session_policy, enabled, status, created_at, updated_at
     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)`,
  )
    .bind(
      id,
      workspaceId,
      agentId,
      pluginId,
      pluginVersionPolicy,
      name,
      JSON.stringify(roles),
      JSON.stringify(capabilities),
      JSON.stringify(config),
      JSON.stringify(secretRefs),
      billingMode,
      JSON.stringify(costMetadata ?? {}),
      independenceKey,
      concurrencyLimit,
      sessionPolicy,
      enabled ? 1 : 0,
      availability,
      now,
      now,
    )
    .run();

  await recordAudit(env, context, "worker.created", "worker", id, {
    agentId,
    pluginId,
    enabled,
  });

  return json({ worker }, { status: 201 });
}

async function handleGetWorker(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  workerId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "agents:read");
  requireWorkspaceContext(context, env, workspaceId);

  const row = await env.CONCLAVE_DB.prepare(
    `SELECT id, workspace_id as workspaceId, agent_id as agentId, plugin_id as pluginId,
            plugin_version_policy as pluginVersionPolicy, name, roles_json as rolesJson,
            capabilities_json as capabilitiesJson, config_json as configJson,
            secret_refs_json as secretRefsJson, billing_mode as billingMode,
            cost_metadata_json as costMetadataJson, independence_key as independenceKey,
            concurrency_limit as concurrencyLimit, session_policy as sessionPolicy,
            enabled, status, created_at as createdAt, updated_at as updatedAt
     FROM workers WHERE workspace_id = ?1 AND id = ?2`,
  )
    .bind(workspaceId, workerId)
    .first<Record<string, unknown>>();

  if (!row) {
    return json({ error: "Worker not found" }, { status: 404 });
  }

  const worker = {
    id: String(row.id),
    workspaceId: String(row.workspaceId),
    agentId: String(row.agentId),
    pluginId: String(row.pluginId),
    pluginVersionPolicy: String(row.pluginVersionPolicy),
    name: String(row.name),
    roles: parseJson(row.rolesJson, []),
    capabilities: parseJson(row.capabilitiesJson, []),
    config: parseJson(row.configJson, {}),
    secretRefs: parseJson(row.secretRefsJson, []),
    billingMode: String(row.billingMode),
    costMetadata: parseJson(row.costMetadataJson, {}),
    independenceKey: String(row.independenceKey),
    concurrencyLimit: Number(row.concurrencyLimit),
    sessionPolicy: String(row.sessionPolicy || "stateless"),
    enabled: Number(row.enabled) === 1,
    availability: String(row.status || "available"),
    createdAt: String(row.createdAt),
    updatedAt: String(row.updatedAt),
  };

  return json({ worker });
}

async function handleUpdateWorker(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  workerId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "agents:manage");
  requireWorkspaceContext(context, env, workspaceId);

  const existing = await env.CONCLAVE_DB.prepare(
    `SELECT * FROM workers WHERE workspace_id = ?1 AND id = ?2`,
  )
    .bind(workspaceId, workerId)
    .first<Record<string, unknown>>();

  if (!existing) {
    return json({ error: "Worker not found" }, { status: 404 });
  }

  const body = (await request.json()) as Record<string, unknown>;
  const now = new Date().toISOString();

  const name =
    typeof body.name === "string" ? body.name : String(existing.name);
  const pluginVersionPolicy =
    typeof body.pluginVersionPolicy === "string"
      ? body.pluginVersionPolicy
      : String(existing.plugin_version_policy || "latest");
  const roles = Array.isArray(body.roles)
    ? (body.roles as string[])
    : parseJson(existing.roles_json, ["implementer"]);
  const capabilities = Array.isArray(body.capabilities)
    ? (body.capabilities as string[])
    : parseJson(existing.capabilities_json, ["code_execution"]);
  const config = (
    typeof body.config === "object" && body.config !== null
      ? body.config
      : parseJson(existing.config_json, {})
  ) as Record<string, unknown>;
  const secretRefs = Array.isArray(body.secretRefs)
    ? (body.secretRefs as string[])
    : parseJson(existing.secret_refs_json, []);
  const billingMode = (
    typeof body.billingMode === "string"
      ? body.billingMode
      : String(existing.billing_mode)
  ) as Worker["billingMode"];
  const costMetadata =
    typeof body.costMetadata === "object" && body.costMetadata !== null
      ? (body.costMetadata as WorkerCostMetadata)
      : (parseJson(existing.cost_metadata_json, undefined) as
          WorkerCostMetadata | undefined);
  const independenceKey =
    typeof body.independenceKey === "string"
      ? body.independenceKey
      : String(existing.independence_key);
  const concurrencyLimit =
    typeof body.concurrencyLimit === "number" && body.concurrencyLimit >= 1
      ? Math.floor(body.concurrencyLimit)
      : Number(existing.concurrency_limit || 1);
  const sessionPolicy = (
    typeof body.sessionPolicy === "string"
      ? body.sessionPolicy
      : String(existing.session_policy || "stateless")
  ) as Worker["sessionPolicy"];
  const enabled =
    typeof body.enabled === "boolean"
      ? body.enabled
      : Number(existing.enabled) === 1;
  const availability = (
    typeof body.availability === "string"
      ? body.availability
      : String(existing.status || "available")
  ) as Worker["availability"];

  const worker: Worker = {
    id: workerId,
    workspaceId,
    agentId: String(existing.agent_id),
    pluginId: String(existing.plugin_id),
    pluginVersionPolicy,
    name,
    roles,
    capabilities,
    config,
    secretRefs,
    enabled,
    availability,
    billingMode,
    costMetadata,
    independenceKey,
    concurrencyLimit,
    sessionPolicy,
    createdAt: String(existing.created_at),
    updatedAt: now,
  };

  try {
    validateWorker(worker);
  } catch (err) {
    return json(
      { error: err instanceof Error ? err.message : String(err) },
      { status: 400 },
    );
  }

  await env.CONCLAVE_DB.prepare(
    `UPDATE workers SET
       name = ?1, plugin_version_policy = ?2, roles_json = ?3,
       capabilities_json = ?4, config_json = ?5, secret_refs_json = ?6,
       billing_mode = ?7, cost_metadata_json = ?8, independence_key = ?9,
       concurrency_limit = ?10, session_policy = ?11, enabled = ?12,
       status = ?13, updated_at = ?14
     WHERE workspace_id = ?15 AND id = ?16`,
  )
    .bind(
      name,
      pluginVersionPolicy,
      JSON.stringify(roles),
      JSON.stringify(capabilities),
      JSON.stringify(config),
      JSON.stringify(secretRefs),
      billingMode,
      JSON.stringify(costMetadata ?? {}),
      independenceKey,
      concurrencyLimit,
      sessionPolicy,
      enabled ? 1 : 0,
      availability,
      now,
      workspaceId,
      workerId,
    )
    .run();

  await recordAudit(env, context, "worker.updated", "worker", workerId, {
    enabled,
    availability,
  });

  return json({ worker });
}

async function handleDeleteWorker(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  workerId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "agents:manage");
  requireWorkspaceContext(context, env, workspaceId);

  await env.CONCLAVE_DB.prepare(
    `DELETE FROM workers WHERE workspace_id = ?1 AND id = ?2`,
  )
    .bind(workspaceId, workerId)
    .run();

  await recordAudit(env, context, "worker.deleted", "worker", workerId);

  return json({ ok: true });
}

async function handleDispatchTaskAssignment(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  taskId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "runs:control");
  requireWorkspaceContext(context, env, workspaceId);

  const body = ((await request.json().catch(() => ({}))) || {}) as Record<
    string,
    unknown
  >;

  const taskRow = await env.CONCLAVE_DB.prepare(
    `SELECT t.id, t.phase_id as phaseId, t.role, t.objective, t.capabilities_json as capabilitiesJson,
            ph.run_id as runId, r.project_id as projectId
     FROM tasks t
     JOIN phases ph ON ph.id = t.phase_id
     JOIN runs r ON r.id = ph.run_id
     WHERE t.id = ?1 AND r.workspace_id = ?2`,
  )
    .bind(taskId, workspaceId)
    .first<Record<string, unknown>>();

  if (!taskRow) {
    return json({ error: "Task not found" }, { status: 404 });
  }

  const runId = String(taskRow.runId);
  const task: TaskToDispatch = {
    id: String(taskRow.id),
    role: (body.role as string) || String(taskRow.role || "implementer"),
    objective: (body.objective as string) || String(taskRow.objective || ""),
    capabilities: Array.isArray(body.capabilities)
      ? (body.capabilities as string[])
      : parseJson(taskRow.capabilitiesJson, []),
    input:
      typeof body.input === "object" && body.input !== null
        ? (body.input as Record<string, unknown>)
        : undefined,
    contextArtifactIds: Array.isArray(body.contextArtifactIds)
      ? (body.contextArtifactIds as string[])
      : undefined,
    timeoutMs: typeof body.timeoutMs === "number" ? body.timeoutMs : undefined,
    requiresIndependentVerification: Boolean(
      body.requiresIndependentVerification,
    ),
  };

  const explicitWorkerId =
    typeof body.workerId === "string" ? body.workerId : undefined;
  const excludeIndependenceKeys = Array.isArray(body.excludeIndependenceKeys)
    ? (body.excludeIndependenceKeys as string[])
    : undefined;

  const result = await dispatchTaskAssignment(
    env as unknown as AssignmentDispatcherEnv,
    {
      workspaceId,
      runId,
      taskId,
      task,
      explicitWorkerId,
      excludeIndependenceKeys,
    },
  );

  if (result.status === "failed") {
    return json(
      {
        error: result.error || "Failed to dispatch task assignment",
        assignment: result,
      },
      { status: 422 },
    );
  }

  return json({ assignment: result }, { status: 200 });
}

async function handleInternalDispatchTaskAssignment(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const configuredToken = env.CONCLAVE_FORGE_CALLBACK_TOKEN;
  if (!configuredToken || bearer(request) !== configuredToken) {
    throw new HttpError(401, "Internal Forge dispatch authentication required");
  }

  const body = ((await request.json().catch(() => ({}))) || {}) as Record<
    string,
    unknown
  >;
  const workspaceId = requiredString(body.workspaceId, "workspaceId");
  const taskId = requiredString(body.taskId, "taskId");
  const runId = requiredString(body.runId, "runId");
  const task = body.task;
  if (typeof task !== "object" || task === null) {
    return json({ error: "task is required" }, { status: 400 });
  }

  const result = await dispatchTaskAssignment(
    env as unknown as AssignmentDispatcherEnv,
    {
      workspaceId,
      runId,
      taskId,
      explicitWorkerId:
        typeof body.workerId === "string" ? body.workerId : undefined,
      task: task as TaskToDispatch,
    },
  );
  if (result.status === "failed") {
    return json(
      {
        error: result.error || "Failed to dispatch task assignment",
        assignment: result,
      },
      { status: 422 },
    );
  }
  return json({ assignment: result });
}

async function handleCancelTaskAssignment(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  assignmentId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "runs:control");
  requireWorkspaceContext(context, env, workspaceId);

  const body = ((await request.json().catch(() => ({}))) || {}) as Record<
    string,
    unknown
  >;
  const reason =
    typeof body.reason === "string" ? body.reason : "Cancelled via API";

  const result = await cancelTaskAssignment(
    env as unknown as AssignmentDispatcherEnv,
    workspaceId,
    assignmentId,
    reason,
  );

  return json(result, { status: 200 });
}

async function handleDispatchEnsembleTaskAssignment(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  taskId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "runs:control");
  requireWorkspaceContext(context, env, workspaceId);

  const body = ((await request.json().catch(() => ({}))) || {}) as Record<
    string,
    unknown
  >;

  const taskRow = await env.CONCLAVE_DB.prepare(
    `SELECT t.id, t.phase_id as phaseId, t.role, t.objective, t.capabilities_json as capabilitiesJson,
            ph.run_id as runId, r.project_id as projectId
     FROM tasks t
     JOIN phases ph ON ph.id = t.phase_id
     JOIN runs r ON r.id = ph.run_id
     WHERE t.id = ?1 AND r.workspace_id = ?2`,
  )
    .bind(taskId, workspaceId)
    .first<Record<string, unknown>>();

  if (!taskRow) {
    return json({ error: "Task not found" }, { status: 404 });
  }

  const runId = String(taskRow.runId);
  const task: TaskToDispatch = {
    id: String(taskRow.id),
    role: (body.role as string) || String(taskRow.role || "implementer"),
    objective: (body.objective as string) || String(taskRow.objective || ""),
    capabilities: Array.isArray(body.capabilities)
      ? (body.capabilities as string[])
      : parseJson(taskRow.capabilitiesJson, []),
    input:
      typeof body.input === "object" && body.input !== null
        ? (body.input as Record<string, unknown>)
        : undefined,
    contextArtifactIds: Array.isArray(body.contextArtifactIds)
      ? (body.contextArtifactIds as string[])
      : undefined,
    timeoutMs: typeof body.timeoutMs === "number" ? body.timeoutMs : undefined,
  };

  const policy = (
    typeof body.policy === "object" && body.policy !== null
      ? body.policy
      : { mode: "parallel" }
  ) as EnsembleDispatchParams["policy"];

  try {
    const result = await dispatchEnsembleTaskAssignment(
      env as unknown as AssignmentDispatcherEnv,
      {
        workspaceId,
        runId,
        taskId,
        task,
        policy,
        explicitCandidateWorkerIds: Array.isArray(body.candidateWorkerIds)
          ? (body.candidateWorkerIds as string[])
          : undefined,
        synthesizerWorkerId:
          typeof body.synthesizerWorkerId === "string"
            ? body.synthesizerWorkerId
            : undefined,
        selectorWorkerId:
          typeof body.selectorWorkerId === "string"
            ? body.selectorWorkerId
            : undefined,
        reviewerWorkerIds: Array.isArray(body.reviewerWorkerIds)
          ? (body.reviewerWorkerIds as string[])
          : undefined,
        candidateWorkspaces: Array.isArray(body.candidateWorkspaces)
          ? (body.candidateWorkspaces as string[])
          : undefined,
      },
    );

    return json({ ensemble: result }, { status: 200 });
  } catch (err) {
    return json(
      { error: err instanceof Error ? err.message : String(err) },
      { status: 422 },
    );
  }
}

async function handleAgentGatewayConnect(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    return json({ error: "Expected WebSocket upgrade" }, { status: 426 });
  }

  const url = new URL(request.url);
  const agentId = url.searchParams.get("agentId");
  const authToken =
    extractAuthToken(request.headers) ??
    url.searchParams.get("token") ??
    url.searchParams.get("authToken");

  if (!agentId || !authToken) {
    return json(
      { error: "agentId and authToken are required" },
      { status: 401 },
    );
  }

  const tokenHash = await hashToken(authToken);
  const agent = await env.CONCLAVE_DB.prepare(
    `SELECT id, workspace_id, status FROM agents WHERE id = ?1 AND auth_token_hash = ?2 AND revoked_at IS NULL`,
  )
    .bind(agentId, tokenHash)
    .first<{ id: string; workspace_id: string; status: string }>();

  if (!agent) {
    return json(
      { error: "Invalid agent credentials or agent is revoked" },
      { status: 401 },
    );
  }

  const targetUrl = new URL(request.url);
  targetUrl.searchParams.set("workspaceId", agent.workspace_id);
  const upgradedRequest = new Request(targetUrl.toString(), request);

  const stub = env.CONCLAVE_AGENT_GATEWAY.getByName(agentId);
  return stub.fetch(upgradedRequest);
}

async function handleAgentProtocolMessage(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const bodyText = await request.text();
  const parsedJson = parseJson(bodyText, null);
  if (!parsedJson) {
    return json({ error: "Malformed JSON" }, { status: 400 });
  }

  let message: AgentProtocolMessage;
  try {
    message = parseAgentMessage(parsedJson);
  } catch (err) {
    return json(
      {
        error:
          err instanceof Error ? err.message : "Invalid agent protocol message",
      },
      { status: 400 },
    );
  }

  const token = extractAuthToken(request.headers);
  if (token) {
    const tokenHash = await hashToken(token);
    const agent = await env.CONCLAVE_DB.prepare(
      `SELECT id, workspace_id FROM agents WHERE auth_token_hash = ?1 AND revoked_at IS NULL`,
    )
      .bind(tokenHash)
      .first<{ id: string; workspace_id: string }>();
    if (!agent) {
      return json({ error: "Unauthorized agent token" }, { status: 401 });
    }
  }

  const now = new Date().toISOString();
  if (message.type === "agent.hello") {
    return json({
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: `msg-${Date.now()}`,
      correlationId: message.messageId,
      timestamp: now,
      type: "agent.hello.ack",
      payload: {
        sessionId: `sess-${Date.now()}`,
        heartbeatIntervalMs: 15000,
        serverTime: now,
        serverVersion: "2.0.0",
      },
    });
  }

  if (message.type === "agent.heartbeat") {
    return json({
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: `msg-${Date.now()}`,
      correlationId: message.messageId,
      timestamp: now,
      type: "agent.heartbeat.ack",
      payload: {
        acknowledged: true,
        serverTime: now,
      },
    });
  }

  if (message.type === "agent.sync.request") {
    return json({
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: `msg-${Date.now()}`,
      correlationId: message.messageId,
      timestamp: now,
      type: "agent.sync.response",
      payload: {
        desiredPlugins: [],
        desiredWorkers: [],
        activeAssignmentIds: [],
      },
    });
  }

  if (message.type === "assignment.result") {
    await env.CONCLAVE_DB.prepare(
      `UPDATE worker_assignments SET status = 'completed', output_json = ?1, updated_at = ?2 WHERE id = ?3`,
    )
      .bind(JSON.stringify(message.payload), now, message.assignmentId)
      .run();
    return json({ acknowledged: true });
  }

  if (message.type === "assignment.error") {
    await env.CONCLAVE_DB.prepare(
      `UPDATE worker_assignments SET status = 'failed', error_json = ?1, updated_at = ?2 WHERE id = ?3`,
    )
      .bind(JSON.stringify(message.payload), now, message.assignmentId)
      .run();
    return json({ acknowledged: true });
  }

  return json({ acknowledged: true });
}

async function handleStudioSnapshot(
  env: Env,
  request: Request,
  projectId: string | null,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const securityEnv = env as SecurityEnv;
  const context = await authorizeRequest(
    request,
    securityEnv,
    "project:read",
    projectId ?? undefined,
    accessContext,
  );
  const isAnonymous = anonymousDevelopment(securityEnv);
  const projectFilter =
    projectId === null
      ? isAnonymous
        ? ""
        : " WHERE p.workspace_id = ?1"
      : isAnonymous
        ? " WHERE p.id = ?1"
        : " WHERE p.id = ?2 AND p.workspace_id = ?1";
  const bind =
    projectId === null
      ? isAnonymous
        ? []
        : [context.workspaceId]
      : isAnonymous
        ? [projectId]
        : [context.workspaceId, projectId];
  const ownership =
    projectId === null
      ? isAnonymous
        ? "1 = 1"
        : "p.workspace_id = ?1"
      : isAnonymous
        ? "p.id = ?1"
        : "p.workspace_id = ?1 AND p.id = ?2";
  const ownershipBind = bind;
  const [
    projects,
    workers,
    agents,
    plugins,
    tasks,
    findings,
    events,
    artifacts,
    modelCalls,
    activeRun,
    latestRun,
  ] = await Promise.all([
    env.CONCLAVE_DB.prepare(
      `SELECT p.id, p.name, COALESCE(p.repository_id, '') AS repository, '' AS branch, (SELECT COUNT(*) FROM goals g WHERE g.project_id = p.id AND g.status IN ('running', 'waiting')) AS activeGoals, p.updated_at AS lastActivity FROM projects p${projectFilter} ORDER BY p.updated_at DESC`,
    )
      .bind(...bind)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT w.id, w.name, w.agent_id AS agentId, w.plugin_id AS pluginId,
              w.roles_json, w.capabilities_json, w.status, '' AS cost,
              COALESCE(a.name, 'Unassigned') AS agentName,
              COALESCE(wp.display_name, 'Unassigned') AS pluginName
       FROM workers w
       LEFT JOIN agents a ON a.id = w.agent_id
       LEFT JOIN worker_plugins wp ON wp.id = w.plugin_id
       WHERE w.workspace_id = ?1 ORDER BY w.name`,
    )
      .bind(context.workspaceId)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT a.id, a.name, a.hostname, a.status, a.version,
              COALESCE(json_extract(a.capabilities_json, '$.os'), '—') AS os,
              COALESCE(json_extract(a.capabilities_json, '$.arch'), '—') AS architecture,
              a.version AS appVersion, 'stable' AS updateChannel,
              COALESCE(a.last_heartbeat_at, a.updated_at) AS lastSeen,
              (SELECT COUNT(*) FROM agent_plugin_installs i WHERE i.agent_id = a.id) AS pluginCount,
              (SELECT COUNT(*) FROM workers w WHERE w.agent_id = a.id) AS workerCount,
              (SELECT COUNT(*) FROM worker_assignments wa JOIN workers w ON w.id = wa.worker_id
               WHERE w.agent_id = a.id AND wa.status IN ('assigned', 'running')) AS activeTaskCount
       FROM agents a WHERE a.workspace_id = ?1 ORDER BY a.name`,
    )
      .bind(context.workspaceId)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT p.id, p.display_name AS name, p.description, p.publisher,
              COALESCE((SELECT v.version FROM worker_plugin_versions v WHERE v.plugin_id = p.id AND v.is_revoked = 0 ORDER BY v.created_at DESC LIMIT 1), '—') AS version,
              COALESCE((SELECT v.channel FROM worker_plugin_versions v WHERE v.plugin_id = p.id AND v.is_revoked = 0 ORDER BY v.created_at DESC LIMIT 1), '—') AS channel,
              COALESCE((SELECT v.permissions_json FROM worker_plugin_versions v WHERE v.plugin_id = p.id AND v.is_revoked = 0 ORDER BY v.created_at DESC LIMIT 1), '[]') AS permissions,
              COALESCE((SELECT v.supported_os_json FROM worker_plugin_versions v WHERE v.plugin_id = p.id AND v.is_revoked = 0 ORDER BY v.created_at DESC LIMIT 1), '[]') AS supportedOS,
              COALESCE((SELECT v.supported_arch_json FROM worker_plugin_versions v WHERE v.plugin_id = p.id AND v.is_revoked = 0 ORDER BY v.created_at DESC LIMIT 1), '[]') AS supportedArchitecture,
              (SELECT COUNT(DISTINCT i.agent_id) FROM agent_plugin_installs i WHERE i.plugin_id = p.id AND i.status IN ('installed', 'active')) AS installedAgentCount,
              p.status, p.supported_roles_json AS roles, p.supported_capabilities_json AS capabilities
       FROM worker_plugins p
       JOIN workers w ON w.plugin_id = p.id
       WHERE w.workspace_id = ?1 AND p.status <> 'deprecated'
       GROUP BY p.id ORDER BY p.display_name`,
    )
      .bind(context.workspaceId)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT t.id, t.objective AS title, ph.name AS phase, t.status, t.role AS worker, t.objective AS detail, CASE WHEN t.status = 'completed' THEN 1 ELSE 0 END AS progress, '[]' AS dependencies, '—' AS tokens, '—' AS cost FROM tasks t JOIN phases ph ON ph.id = t.phase_id JOIN runs r ON r.id = ph.run_id JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE ${ownership} ORDER BY t.created_at DESC LIMIT 100`,
    )
      .bind(...ownershipBind)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT f.id, f.description AS title, f.description, f.severity, f.status, COALESCE(f.task_id, '') AS taskId, 'Unknown' AS author FROM findings f JOIN runs r ON r.id = f.run_id JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE ${ownership} ORDER BY f.created_at DESC LIMIT 100`,
    )
      .bind(...ownershipBind)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT e.occurred_at AS time, e.event_type AS title, e.entity_id AS detail, e.event_type AS kind FROM events e JOIN runs r ON r.id = e.run_id JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE ${ownership} ORDER BY e.occurred_at DESC LIMIT 100`,
    )
      .bind(...ownershipBind)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT a.id AS name, a.media_type AS type, a.size_bytes AS size, 'Conclave' AS source FROM artifacts a JOIN runs r ON r.id = a.run_id JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE ${ownership} ORDER BY a.created_at DESC LIMIT 100`,
    )
      .bind(...ownershipBind)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT mc.worker_id AS worker, mc.model, mc.attempt_id AS task, u.input_tokens + u.output_tokens AS tokens, u.cost_micros AS cost, u.duration_ms AS duration, mc.status FROM model_calls mc JOIN attempts a ON a.id = mc.attempt_id JOIN tasks t ON t.id = a.task_id JOIN phases ph ON ph.id = t.phase_id JOIN runs r ON r.id = ph.run_id JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id LEFT JOIN usage u ON u.attempt_id = a.id WHERE ${ownership} ORDER BY mc.started_at DESC LIMIT 100`,
    )
      .bind(...ownershipBind)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT r.id FROM runs r JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE ${ownership} AND r.status IN ('active', 'running', 'waiting') ORDER BY r.created_at DESC LIMIT 1`,
    )
      .bind(...ownershipBind)
      .first<{ id: string }>(),
    env.CONCLAVE_DB.prepare(
      `SELECT r.id, r.status, g.objective AS objective, r.created_at AS createdAt, r.started_at AS startedAt, r.finished_at AS finishedAt,
        (SELECT COUNT(*) FROM tasks t JOIN phases ph ON ph.id = t.phase_id WHERE ph.run_id = r.id) AS taskCount,
        (SELECT COUNT(*) FROM tasks t JOIN phases ph ON ph.id = t.phase_id WHERE ph.run_id = r.id AND t.status = 'completed') AS completedTaskCount,
        (SELECT COUNT(*) FROM findings f WHERE f.run_id = r.id AND f.status IN ('open', 'fixed')) AS openFindingCount,
        (SELECT COUNT(*) FROM completion_criteria cc WHERE cc.goal_id = g.id AND cc.status = 'verified') AS verifiedCriterionCount,
        (SELECT COUNT(*) FROM completion_criteria cc WHERE cc.goal_id = g.id) AS criterionCount,
        COALESCE((SELECT SUM(input_tokens + output_tokens) FROM usage u WHERE u.run_id = r.id), 0) AS tokens,
        COALESCE((SELECT SUM(cost_micros) FROM usage u WHERE u.run_id = r.id), 0) AS costMicros
       FROM runs r JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE ${ownership} ORDER BY r.created_at DESC LIMIT 1`,
    )
      .bind(...ownershipBind)
      .first(),
  ]);
  const chatFilter =
    projectId === null
      ? isAnonymous
        ? "1 = 1"
        : "c.workspace_id = ?1"
      : isAnonymous
        ? "c.project_id = ?1"
        : "c.workspace_id = ?1 AND c.project_id = ?2";
  const chatBind =
    projectId === null
      ? isAnonymous
        ? []
        : [context.workspaceId]
      : isAnonymous
        ? [projectId]
        : [context.workspaceId, projectId];
  const [chats, chatMessages] = await Promise.all([
    env.CONCLAVE_DB.prepare(
      `SELECT c.id, c.project_id AS projectId, c.workspace_id AS workspaceId,
              c.created_by_user_id AS createdByUserId, c.title, c.status,
              c.created_at AS createdAt, c.updated_at AS updatedAt
       FROM chats c WHERE ${chatFilter} ORDER BY c.updated_at DESC`,
    )
      .bind(...chatBind)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT m.id, m.chat_id AS chatId, m.sender_type AS senderType,
              m.content, m.kind, m.goal_id AS goalId, m.metadata_json AS metadata,
              m.created_at AS createdAt
       FROM chat_messages m
       JOIN chats c ON c.id = m.chat_id
       WHERE ${chatFilter}
       ORDER BY m.created_at ASC`,
    )
      .bind(...chatBind)
      .all(),
  ]);
  const mapJson = (value: unknown): string[] =>
    typeof value === "string" ? (JSON.parse(value) as string[]) : [];
  const mapObject = (value: unknown): Record<string, unknown> => {
    if (typeof value !== "string") return {};
    try {
      const parsed: unknown = JSON.parse(value);
      return typeof parsed === "object" && parsed !== null
        ? (parsed as Record<string, unknown>)
        : {};
    } catch {
      return {};
    }
  };
  const messagesByChat = new Map<string, Record<string, unknown>[]>();
  for (const row of chatMessages.results ?? []) {
    const chatId = String(row.chatId);
    const metadata = mapObject(row.metadata);
    const sender =
      row.senderType === "user"
        ? "user"
        : row.senderType === "system"
          ? "system"
          : "conclave";
    const message = {
      id: row.id,
      sender,
      text: row.content,
      timestamp: row.createdAt,
      ...(metadata.runPreview ? { runPreview: metadata.runPreview } : {}),
    };
    const existing = messagesByChat.get(chatId) ?? [];
    existing.push(message);
    messagesByChat.set(chatId, existing);
  }
  const chatsByProject = new Map<string, Record<string, unknown>[]>();
  for (const row of chats.results ?? []) {
    const chat = {
      id: row.id,
      projectId: row.projectId,
      workspaceId: row.workspaceId,
      createdByUserId: row.createdByUserId,
      title: row.title,
      status: row.status,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      lastActivity: row.updatedAt,
      messages: messagesByChat.get(String(row.id)) ?? [],
    };
    const projectChats = chatsByProject.get(String(row.projectId)) ?? [];
    projectChats.push(chat);
    chatsByProject.set(String(row.projectId), projectChats);
  }
  return json({
    workspaceId: context.workspaceId,
    viewer: {
      id: context.userId,
      displayName: context.user.displayName,
      email: context.user.email,
    },
    activeRunId: activeRun?.id ?? null,
    run: latestRun ?? null,
    projects: (projects.results ?? []).map((project) => ({
      ...project,
      chats: chatsByProject.get(String(project.id)) ?? [],
    })),
    workers: (workers.results ?? []).map((row) => ({
      ...row,
      role: mapJson(row.roles_json)[0] ?? "worker",
      roles: mapJson(row.roles_json),
      capabilities: mapJson(row.capabilities_json),
      status: row.status ?? "unknown",
    })),
    agents: agents.results ?? [],
    plugins: (plugins.results ?? []).map((row) => ({
      ...row,
      roles: mapJson(row.roles),
      capabilities: mapJson(row.capabilities),
      permissions: mapJson(row.permissions),
      supportedOS: mapJson(row.supportedOS),
      supportedArchitecture: mapJson(row.supportedArchitecture),
      status: row.status === "active" ? "Installed" : row.status,
    })),
    tasks: (tasks.results ?? []).map((row) => ({
      ...row,
      dependencies: mapJson(row.dependencies),
    })),
    findings: findings.results ?? [],
    events: events.results ?? [],
    artifacts: artifacts.results ?? [],
    modelCalls: modelCalls.results ?? [],
  });
}

async function validateAndClaimCiEvidence(
  env: Env,
  runId: string,
  input: unknown,
): Promise<string> {
  let evidence;
  try {
    evidence = parseMachineCheckEvidence(input);
  } catch (error) {
    throw new HttpError(
      400,
      `Invalid CI evidence: ${error instanceof Error ? error.message : "unknown"}`,
    );
  }
  if (evidence.runId !== runId)
    throw new HttpError(409, "CI evidence does not belong to this run");
  const expected = await env.CONCLAVE_DB.prepare(
    `SELECT r.policy_snapshot_json, p.repository_id, p.workspace_id
     FROM runs r JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id
     WHERE r.id = ?1`,
  )
    .bind(runId)
    .first<{
      policy_snapshot_json: string;
      repository_id: string | null;
      workspace_id: string | null;
    }>();
  if (!expected) throw new HttpError(404, "Run not found");
  let policy: Record<string, unknown> = {};
  try {
    const parsed: unknown = JSON.parse(expected.policy_snapshot_json);
    if (typeof parsed === "object" && parsed !== null)
      policy = parsed as Record<string, unknown>;
  } catch {
    throw new HttpError(409, "Run has no valid CI correlation policy");
  }
  const expectedRepository =
    typeof policy.repositoryId === "string"
      ? policy.repositoryId
      : expected.repository_id;
  const expectedCommitSha =
    typeof policy.expectedCommitSha === "string"
      ? policy.expectedCommitSha
      : undefined;
  const allowedWorkflows = Array.isArray(policy.allowedWorkflows)
    ? policy.allowedWorkflows.filter(
        (value): value is string => typeof value === "string",
      )
    : ["CI"];
  const expectedChecks = Array.isArray(policy.expectedChecks)
    ? policy.expectedChecks.filter(
        (value): value is string => typeof value === "string",
      )
    : [];
  if (!expectedRepository || evidence.repositoryId !== expectedRepository)
    throw new HttpError(409, "CI evidence repository does not match this run");
  if (!expectedCommitSha || evidence.commitSha !== expectedCommitSha)
    throw new HttpError(409, "CI evidence commit SHA does not match this run");
  if (!allowedWorkflows.includes(evidence.workflow))
    throw new HttpError(409, "CI workflow is not allowed for this run");
  const receivedChecks = new Set(evidence.checks.map((check) => check.name));
  for (const expectedCheck of expectedChecks) {
    if (!receivedChecks.has(expectedCheck))
      throw new HttpError(
        409,
        `Expected CI check is missing: ${expectedCheck}`,
      );
  }
  if (!expected.workspace_id)
    throw new HttpError(409, "Run has no workspace correlation");
  try {
    await env.CONCLAVE_DB.prepare(
      `INSERT INTO ci_evidence
       (evidence_id, workspace_id, run_id, repository_id, external_run_id, revision, workflow,
        source, conclusion, checks_json, smoke_tests_json, health_checks_json, raw_payload_json,
        observed_at, status, claimed_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, 'claimed', ?15)`,
    )
      .bind(
        evidence.evidenceId,
        expected.workspace_id,
        runId,
        evidence.repositoryId,
        evidence.externalRunId,
        evidence.commitSha,
        evidence.workflow,
        evidence.source,
        evidence.conclusion,
        JSON.stringify(evidence.checks),
        JSON.stringify(evidence.smokeTests),
        JSON.stringify(evidence.healthChecks),
        JSON.stringify(input),
        evidence.observedAt,
        new Date().toISOString(),
      )
      .run();
  } catch (error) {
    throw new HttpError(
      409,
      `CI evidence was already received: ${errorMessage(error)}`,
    );
  }
  return evidence.evidenceId;
}

async function handleRunCommand(
  request: Request,
  env: Env,
  runId: string,
  command:
    | "pause"
    | "resume"
    | "restart"
    | "cancel"
    | "event"
    | "ci-evidence"
    | "forge-terminal",
  accessContext?: ExecutionContext,
): Promise<Response> {
  const securityEnv = env as SecurityEnv;
  let controlContext: SecurityContext | undefined;
  if (command === "ci-evidence") requireCiAuthentication(request, securityEnv);
  if (command === "forge-terminal") {
    requireForgeCallbackAuthentication(request, securityEnv);
  } else {
    const projectId = anonymousDevelopment(securityEnv)
      ? undefined
      : await runProjectId(securityEnv, runId);
    controlContext = await authorizeRequest(
      request,
      securityEnv,
      "run:control",
      projectId,
      accessContext,
    );
  }
  const workflowInstanceId = await resolveWorkflowInstanceId(env, runId);
  const instance = await env.CONCLAVE_RUN_WORKFLOW.get(workflowInstanceId);
  let claimedEvidenceId: string | undefined;
  if (command === "ci-evidence") {
    const body = (await request.clone().json()) as Record<string, unknown>;
    claimedEvidenceId = await validateAndClaimCiEvidence(
      env,
      runId,
      body.payload ?? body,
    );
  }
  if (command === "pause") await instance.pause();
  if (command === "resume") await instance.resume();
  if (command === "restart") await instance.restart();
  if (command === "cancel") await instance.terminate();
  if (command === "pause" || command === "resume" || command === "cancel") {
    const status =
      command === "pause"
        ? "paused"
        : command === "cancel"
          ? "cancelled"
          : "running";
    await env.CONCLAVE_DB.prepare(
      "UPDATE runs SET status = ?1, finished_at = CASE WHEN ?1 = 'cancelled' THEN ?2 ELSE finished_at END, updated_at = ?2 WHERE id = ?3",
    )
      .bind(status, new Date().toISOString(), runId)
      .run();
  }
  if (controlContext && command !== "ci-evidence") {
    await recordAudit(
      env as SecurityEnv,
      controlContext,
      `run.${command}`,
      "run",
      runId,
    );
  }
  if (
    command === "event" ||
    command === "ci-evidence" ||
    command === "forge-terminal"
  ) {
    const body = (await request.json()) as Record<string, unknown>;
    if (command === "ci-evidence") {
      await instance.sendEvent({
        type: "ci-evidence",
        payload: body.payload ?? body,
      });
      await env.CONCLAVE_DB.prepare(
        "UPDATE ci_evidence SET status = 'consumed', consumed_at = ?1 WHERE evidence_id = ?2 AND status = 'claimed'",
      )
        .bind(new Date().toISOString(), claimedEvidenceId)
        .run();
    } else if (command === "forge-terminal") {
      await instance.sendEvent({
        type: "forge-terminal",
        payload: body.payload ?? body,
      });
    } else {
      const type = requiredString(body.type, "type");
      if (type !== "run-control" && type !== "run-approval") {
        throw new Error("Unsupported workflow event type");
      }
      await instance.sendEvent({ type, payload: body.payload });
    }
  }
  return json({
    id: runId,
    workflowInstanceId,
    status: (await instance.status()).status,
  });
}

// =========================================================================
// Plugin Registry Handlers (Architecture v2)
// =========================================================================

async function handleListPlugins(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const url = new URL(request.url);
  const channel = url.searchParams.get("channel"); // 'stable' | 'beta' | 'development'
  const role = url.searchParams.get("role");
  const capability = url.searchParams.get("capability");
  const status = url.searchParams.get("status") ?? "active";
  const query = url.searchParams.get("query")?.toLowerCase();

  const pluginsResult = await env.CONCLAVE_DB.prepare(
    "SELECT * FROM worker_plugins WHERE status = ?1 ORDER BY id ASC",
  )
    .bind(status)
    .all<{
      id: string;
      display_name: string;
      description: string;
      publisher: string;
      supported_roles_json: string;
      supported_capabilities_json: string;
      status: string;
      created_at: string;
      updated_at: string;
    }>();

  const plugins = pluginsResult.results ?? [];

  const versionsResult = await env.CONCLAVE_DB.prepare(
    "SELECT * FROM worker_plugin_versions ORDER BY created_at DESC",
  ).all<{
    id: string;
    plugin_id: string;
    version: string;
    channel: string;
    protocol_version: string;
    min_agent_version: string;
    max_agent_version: string | null;
    supported_os_json: string;
    supported_arch_json: string;
    package_digest: string;
    package_r2_key: string;
    signature: string;
    permissions_json: string;
    billing_modes_json: string;
    config_schema_json: string;
    secret_schema_json: string;
    is_revoked: number;
    revoked_at: string | null;
    revocation_reason: string | null;
    created_at: string;
  }>();

  const versions = versionsResult.results ?? [];

  const enriched = plugins
    .map((p) => {
      const supportedRoles = parseJson<string[]>(p.supported_roles_json, []);
      const supportedCapabilities = parseJson<string[]>(
        p.supported_capabilities_json,
        [],
      );
      let pluginVersions = versions.filter((v) => v.plugin_id === p.id);
      if (channel) {
        pluginVersions = pluginVersions.filter((v) => v.channel === channel);
      }

      return {
        id: p.id,
        displayName: p.display_name,
        description: p.description,
        publisher: p.publisher,
        status: p.status,
        supportedRoles,
        supportedCapabilities,
        versions: pluginVersions.map((v) => ({
          id: v.id,
          version: v.version,
          channel: v.channel,
          protocolVersion: v.protocol_version,
          minAgentVersion: v.min_agent_version,
          maxAgentVersion: v.max_agent_version,
          supportedOS: parseJson<string[]>(v.supported_os_json, []),
          supportedArchitecture: parseJson<string[]>(v.supported_arch_json, []),
          packageDigest: v.package_digest,
          packageR2Key: v.package_r2_key,
          signature: v.signature,
          permissions: parseJson<string[]>(v.permissions_json, []),
          billingModes: parseJson<string[]>(v.billing_modes_json, []),
          configSchema: parseJson<Record<string, unknown>>(
            v.config_schema_json,
            {},
          ),
          secretSchema: parseJson<Record<string, unknown>>(
            v.secret_schema_json,
            {},
          ),
          isRevoked: v.is_revoked === 1,
          revokedAt: v.revoked_at,
          revocationReason: v.revocation_reason,
          createdAt: v.created_at,
        })),
        createdAt: p.created_at,
        updatedAt: p.updated_at,
      };
    })
    .filter((p) => {
      if (role && !p.supportedRoles.includes(role)) return false;
      if (capability && !p.supportedCapabilities.includes(capability))
        return false;
      if (query) {
        const text = `${p.id} ${p.displayName} ${p.description}`.toLowerCase();
        if (!text.includes(query)) return false;
      }
      return true;
    });

  return json({ plugins: enriched });
}

async function handleGetPlugin(
  env: SecurityEnv,
  pluginId: string,
): Promise<Response> {
  const plugin = await env.CONCLAVE_DB.prepare(
    "SELECT * FROM worker_plugins WHERE id = ?1",
  )
    .bind(pluginId)
    .first<{
      id: string;
      display_name: string;
      description: string;
      publisher: string;
      supported_roles_json: string;
      supported_capabilities_json: string;
      status: string;
      created_at: string;
      updated_at: string;
    }>();

  if (!plugin) {
    return json({ error: `Plugin '${pluginId}' not found` }, { status: 404 });
  }

  const versionsResult = await env.CONCLAVE_DB.prepare(
    "SELECT * FROM worker_plugin_versions WHERE plugin_id = ?1 ORDER BY created_at DESC",
  )
    .bind(pluginId)
    .all<{
      id: string;
      plugin_id: string;
      version: string;
      channel: string;
      protocol_version: string;
      min_agent_version: string;
      max_agent_version: string | null;
      supported_os_json: string;
      supported_arch_json: string;
      package_digest: string;
      package_r2_key: string;
      signature: string;
      permissions_json: string;
      billing_modes_json: string;
      config_schema_json: string;
      secret_schema_json: string;
      is_revoked: number;
      revoked_at: string | null;
      revocation_reason: string | null;
      created_at: string;
    }>();

  const versions = (versionsResult.results ?? []).map((v) => ({
    id: v.id,
    version: v.version,
    channel: v.channel,
    protocolVersion: v.protocol_version,
    minAgentVersion: v.min_agent_version,
    maxAgentVersion: v.max_agent_version,
    supportedOS: parseJson<string[]>(v.supported_os_json, []),
    supportedArchitecture: parseJson<string[]>(v.supported_arch_json, []),
    packageDigest: v.package_digest,
    packageR2Key: v.package_r2_key,
    signature: v.signature,
    permissions: parseJson<string[]>(v.permissions_json, []),
    billingModes: parseJson<string[]>(v.billing_modes_json, []),
    configSchema: parseJson<Record<string, unknown>>(v.config_schema_json, {}),
    secretSchema: parseJson<Record<string, unknown>>(v.secret_schema_json, {}),
    isRevoked: v.is_revoked === 1,
    revokedAt: v.revoked_at,
    revocationReason: v.revocation_reason,
    createdAt: v.created_at,
  }));

  const latestByChannel: Record<string, string> = {};
  for (const v of versions) {
    if (!v.isRevoked && !latestByChannel[v.channel]) {
      latestByChannel[v.channel] = v.version;
    }
  }

  return json({
    id: plugin.id,
    displayName: plugin.display_name,
    description: plugin.description,
    publisher: plugin.publisher,
    status: plugin.status,
    supportedRoles: parseJson<string[]>(plugin.supported_roles_json, []),
    supportedCapabilities: parseJson<string[]>(
      plugin.supported_capabilities_json,
      [],
    ),
    latestByChannel,
    versions,
    createdAt: plugin.created_at,
    updatedAt: plugin.updated_at,
  });
}

async function handleGetPluginVersion(
  env: SecurityEnv,
  pluginId: string,
  version: string,
): Promise<Response> {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT * FROM worker_plugin_versions WHERE plugin_id = ?1 AND version = ?2",
  )
    .bind(pluginId, version)
    .first<{
      id: string;
      plugin_id: string;
      version: string;
      channel: string;
      protocol_version: string;
      min_agent_version: string;
      max_agent_version: string | null;
      supported_os_json: string;
      supported_arch_json: string;
      package_digest: string;
      package_r2_key: string;
      signature: string;
      permissions_json: string;
      billing_modes_json: string;
      config_schema_json: string;
      secret_schema_json: string;
      is_revoked: number;
      revoked_at: string | null;
      revocation_reason: string | null;
      created_at: string;
    }>();

  if (!row) {
    return json(
      { error: `Plugin version '${pluginId}@${version}' not found` },
      { status: 404 },
    );
  }

  return json({
    id: row.id,
    pluginId: row.plugin_id,
    version: row.version,
    channel: row.channel,
    protocolVersion: row.protocol_version,
    minAgentVersion: row.min_agent_version,
    maxAgentVersion: row.max_agent_version,
    supportedOS: parseJson<string[]>(row.supported_os_json, []),
    supportedArchitecture: parseJson<string[]>(row.supported_arch_json, []),
    packageDigest: row.package_digest,
    packageR2Key: row.package_r2_key,
    signature: row.signature,
    permissions: parseJson<string[]>(row.permissions_json, []),
    billingModes: parseJson<string[]>(row.billing_modes_json, []),
    configSchema: parseJson<Record<string, unknown>>(
      row.config_schema_json,
      {},
    ),
    secretSchema: parseJson<Record<string, unknown>>(
      row.secret_schema_json,
      {},
    ),
    isRevoked: row.is_revoked === 1,
    revokedAt: row.revoked_at,
    revocationReason: row.revocation_reason,
    createdAt: row.created_at,
  });
}

async function handleDownloadPluginVersion(
  request: Request,
  env: SecurityEnv,
  pluginId: string,
  version: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  if (!anonymousDevelopment(env)) {
    const token = extractAuthToken(request.headers);
    if (token) {
      const tokenHash = await hashToken(token);
      const agent = await env.CONCLAVE_DB.prepare(
        `SELECT a.id, a.workspace_id
         FROM agents a
         JOIN workers w ON w.agent_id = a.id AND w.workspace_id = a.workspace_id
         WHERE a.auth_token_hash = ?1
           AND a.revoked_at IS NULL
           AND w.plugin_id = ?2
           AND w.enabled = 1
         LIMIT 1`,
      )
        .bind(tokenHash, pluginId)
        .first<{ id: string; workspace_id: string }>();
      if (!agent) {
        return json(
          { error: "Agent is not authorized to download this plugin" },
          { status: 403 },
        );
      }
    } else {
      await authorizeRequest(request, env, "workers:read", undefined, ctx);
    }
  }
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT package_r2_key, package_digest, is_revoked FROM worker_plugin_versions WHERE plugin_id = ?1 AND version = ?2",
  )
    .bind(pluginId, version)
    .first<{
      package_r2_key: string;
      package_digest: string;
      is_revoked: number;
    }>();

  if (!row) {
    return json(
      { error: `Plugin version '${pluginId}@${version}' not found` },
      { status: 404 },
    );
  }

  if (row.is_revoked === 1) {
    return json(
      {
        error: `Plugin version '${pluginId}@${version}' is revoked and cannot be downloaded`,
      },
      { status: 410 },
    );
  }

  const bucket =
    (env as unknown as { CONCLAVE_PLUGINS?: R2Bucket }).CONCLAVE_PLUGINS ??
    env.CONCLAVE_ARTIFACTS;
  if (!bucket) {
    return json({ error: "Storage bucket not configured" }, { status: 500 });
  }

  const object = await bucket.get(row.package_r2_key);
  if (!object) {
    return json(
      { error: "Plugin package file not found in storage" },
      { status: 404 },
    );
  }

  const headers = new Headers();
  headers.set("content-type", "application/gzip");
  headers.set("etag", object.etag);
  headers.set("content-digest", row.package_digest);
  headers.set(
    "content-disposition",
    `attachment; filename="${pluginId}-${version}.tgz"`,
  );

  return new Response(object.body, { headers });
}

async function handlePublishPlugin(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(request, env, "workspace:manage", undefined, ctx);

  const body = (await request.json()) as {
    manifest: Record<string, unknown>;
    packageBase64?: string;
    packageDigest?: string;
    channel?: string;
    signingSecret?: string;
  };

  const manifest = validateWorkerPluginManifest(body.manifest);
  const channel = (body.channel ?? manifest.channel ?? "stable") as
    "stable" | "beta" | "development";

  let packageBytes: Uint8Array;
  if (body.packageBase64) {
    packageBytes = Uint8Array.from(atob(body.packageBase64), (c) =>
      c.charCodeAt(0),
    );
  } else {
    packageBytes = new TextEncoder().encode(JSON.stringify(manifest));
  }

  const computedDigest = await computePackageDigest(packageBytes);
  if (manifest.digest && manifest.digest !== computedDigest) {
    return json(
      {
        error: `Package digest mismatch: manifest declares ${manifest.digest}, but computed package digest is ${computedDigest}`,
      },
      { status: 400 },
    );
  }
  const digest = manifest.digest || computedDigest;

  const signingSecret =
    env.CONCLAVE_PLUGIN_SIGNING_KEY ||
    (env.CONCLAVE_ENVIRONMENT === "development"
      ? body.signingSecret
      : undefined);
  if (!signingSecret) {
    return json(
      { error: "Plugin signing key is not configured" },
      { status: 503 },
    );
  }
  let signature = manifest.signature;
  if (!signature) {
    signature = await signPackageDigest(digest, signingSecret);
  } else {
    const isValid = await verifyPackageDigestSignature(
      digest,
      signature,
      signingSecret,
    );
    if (!isValid) {
      return json({ error: "Invalid package signature" }, { status: 400 });
    }
  }

  const r2Key = `plugins/${manifest.pluginId}/${manifest.version}/${digest.replace(/^sha256:/, "")}.tgz`;
  const bucket =
    (env as unknown as { CONCLAVE_PLUGINS?: R2Bucket }).CONCLAVE_PLUGINS ??
    env.CONCLAVE_ARTIFACTS;
  if (bucket) {
    await bucket.put(r2Key, packageBytes, {
      httpMetadata: { contentType: "application/gzip" },
      customMetadata: {
        pluginId: manifest.pluginId,
        version: manifest.version,
        digest,
        signature,
      },
    });
  }

  const now = new Date().toISOString();

  // 1. Upsert worker_plugins
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO worker_plugins (id, display_name, description, publisher, supported_roles_json, supported_capabilities_json, status, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'active', ?7, ?7)
     ON CONFLICT(id) DO UPDATE SET
       display_name = excluded.display_name,
       description = excluded.description,
       publisher = excluded.publisher,
       supported_roles_json = excluded.supported_roles_json,
       supported_capabilities_json = excluded.supported_capabilities_json,
       updated_at = excluded.updated_at`,
  )
    .bind(
      manifest.pluginId,
      manifest.displayName,
      manifest.description ?? "",
      manifest.publisher,
      JSON.stringify(manifest.roles),
      JSON.stringify(manifest.capabilities),
      now,
    )
    .run();

  // 2. Upsert worker_plugin_versions
  const versionId = `ver-${manifest.pluginId}-${manifest.version}`;
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO worker_plugin_versions (
       id, plugin_id, version, channel, protocol_version, min_agent_version, max_agent_version,
       supported_os_json, supported_arch_json, package_digest, package_r2_key, signature,
       permissions_json, billing_modes_json, config_schema_json, secret_schema_json,
       is_revoked, created_at
     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, 0, ?17)
     ON CONFLICT(plugin_id, version) DO UPDATE SET
       channel = excluded.channel,
       package_digest = excluded.package_digest,
       package_r2_key = excluded.package_r2_key,
       signature = excluded.signature,
       permissions_json = excluded.permissions_json,
       billing_modes_json = excluded.billing_modes_json,
       config_schema_json = excluded.config_schema_json,
       secret_schema_json = excluded.secret_schema_json,
       is_revoked = 0,
       revoked_at = NULL,
       revocation_reason = NULL`,
  )
    .bind(
      versionId,
      manifest.pluginId,
      manifest.version,
      channel,
      manifest.protocolVersion ?? "2.0",
      manifest.minimumAgentVersion ?? "0.2.0",
      null,
      JSON.stringify(manifest.supportedOS),
      JSON.stringify(manifest.supportedArchitecture),
      digest,
      r2Key,
      signature,
      JSON.stringify(manifest.permissions ?? []),
      JSON.stringify(manifest.billingModes ?? ["free"]),
      JSON.stringify(manifest.configurationSchema ?? {}),
      JSON.stringify(manifest.secretSchema ?? {}),
      now,
    )
    .run();

  return json({
    pluginId: manifest.pluginId,
    version: manifest.version,
    channel,
    packageDigest: digest,
    packageR2Key: r2Key,
    signature,
    status: "published",
    publishedAt: now,
  });
}

async function handleRevokePluginVersion(
  request: Request,
  env: SecurityEnv,
  pluginId: string,
  version: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(request, env, "workspace:manage", undefined, ctx);

  const body = (await request.json().catch(() => ({}))) as { reason?: string };
  const reason = body.reason || "Revoked by administrator";
  const now = new Date().toISOString();

  await env.CONCLAVE_DB.prepare(
    `UPDATE worker_plugin_versions
     SET is_revoked = 1, revoked_at = ?1, revocation_reason = ?2
     WHERE plugin_id = ?3 AND version = ?4`,
  )
    .bind(now, reason, pluginId, version)
    .run();

  return json({
    pluginId,
    version,
    isRevoked: true,
    revokedAt: now,
    revocationReason: reason,
  });
}

async function handleDeprecatePlugin(
  request: Request,
  env: SecurityEnv,
  pluginId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(request, env, "workspace:manage", undefined, ctx);

  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `UPDATE worker_plugins SET status = 'deprecated', updated_at = ?1 WHERE id = ?2`,
  )
    .bind(now, pluginId)
    .run();

  return json({
    pluginId,
    status: "deprecated",
    updatedAt: now,
  });
}

// =========================================================================
// Agent Releases API Handlers (Architecture v2 Self-Update)
// =========================================================================

async function handleGetLatestAgentRelease(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const url = new URL(request.url);
  const channel = url.searchParams.get("channel") || "stable";
  const os = url.searchParams.get("os");
  const arch = url.searchParams.get("arch");
  const currentVersion = url.searchParams.get("currentVersion");

  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT version, channel, min_supported_agent_version as minSupportedAgentVersion,
            supported_os_json as supportedOsJson, supported_arch_json as supportedArchJson,
            package_digest as packageDigest, package_r2_key as packageR2Key,
            signature, release_notes as releaseNotes, is_revoked as isRevoked,
            created_at as createdAt
     FROM agent_releases
     WHERE channel = ?1 AND is_revoked = 0
     ORDER BY created_at DESC`,
  )
    .bind(channel)
    .all<{
      version: string;
      channel: string;
      minSupportedAgentVersion: string | null;
      supportedOsJson: string;
      supportedArchJson: string;
      packageDigest: string;
      packageR2Key: string;
      signature: string;
      releaseNotes: string | null;
      isRevoked: number;
      createdAt: string;
    }>();

  const releases = (rows.results ?? []).filter((r) => {
    if (os) {
      const supportedOS = parseJson<string[]>(r.supportedOsJson, []);
      if (!supportedOS.includes(os)) return false;
    }
    if (arch) {
      const supportedArch = parseJson<string[]>(r.supportedArchJson, []);
      if (!supportedArch.includes(arch)) return false;
    }
    return true;
  });

  releases.sort((a, b) => compareSemver(b.version, a.version));

  const latest = releases[0];
  if (!latest) {
    return json({ updateAvailable: false, release: null });
  }

  const updateAvailable = currentVersion
    ? compareSemver(latest.version, currentVersion) > 0
    : true;

  return json({
    updateAvailable,
    release: {
      version: latest.version,
      channel: latest.channel,
      minSupportedAgentVersion: latest.minSupportedAgentVersion,
      supportedOS: parseJson<string[]>(latest.supportedOsJson, []),
      supportedArch: parseJson<string[]>(latest.supportedArchJson, []),
      packageDigest: latest.packageDigest,
      packageR2Key: latest.packageR2Key,
      signature: latest.signature,
      releaseNotes: latest.releaseNotes,
      createdAt: latest.createdAt,
    },
  });
}

async function handleGetAgentRelease(
  env: SecurityEnv,
  version: string,
): Promise<Response> {
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT version, channel, min_supported_agent_version as minSupportedAgentVersion,
            supported_os_json as supportedOsJson, supported_arch_json as supportedArchJson,
            package_digest as packageDigest, package_r2_key as packageR2Key,
            signature, release_notes as releaseNotes, is_revoked as isRevoked,
            revoked_at as revokedAt, revocation_reason as revocationReason,
            created_at as createdAt
     FROM agent_releases WHERE version = ?1`,
  )
    .bind(version)
    .first<{
      version: string;
      channel: string;
      minSupportedAgentVersion: string | null;
      supportedOsJson: string;
      supportedArchJson: string;
      packageDigest: string;
      packageR2Key: string;
      signature: string;
      releaseNotes: string | null;
      isRevoked: number;
      revokedAt: string | null;
      revocationReason: string | null;
      createdAt: string;
    }>();

  if (!row) {
    return json(
      { error: `Agent release '${version}' not found` },
      { status: 404 },
    );
  }

  return json({
    version: row.version,
    channel: row.channel,
    minSupportedAgentVersion: row.minSupportedAgentVersion,
    supportedOS: parseJson<string[]>(row.supportedOsJson, []),
    supportedArch: parseJson<string[]>(row.supportedArchJson, []),
    packageDigest: row.packageDigest,
    packageR2Key: row.packageR2Key,
    signature: row.signature,
    releaseNotes: row.releaseNotes,
    isRevoked: Boolean(row.isRevoked),
    revokedAt: row.revokedAt,
    revocationReason: row.revocationReason,
    createdAt: row.createdAt,
  });
}

async function handleDownloadAgentRelease(
  request: Request,
  env: SecurityEnv,
  version: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  if (!anonymousDevelopment(env)) {
    const token = extractAuthToken(request.headers);
    if (token) {
      const tokenHash = await hashToken(token);
      const agent = await env.CONCLAVE_DB.prepare(
        `SELECT id FROM agents
         WHERE auth_token_hash = ?1 AND revoked_at IS NULL
         LIMIT 1`,
      )
        .bind(tokenHash)
        .first<{ id: string }>();
      if (!agent) {
        return json(
          { error: "Invalid or revoked Agent credential" },
          { status: 401 },
        );
      }
    } else {
      await authorizeRequest(request, env, "agents:read", undefined, ctx);
    }
  }
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT package_r2_key, package_digest, is_revoked, revocation_reason FROM agent_releases WHERE version = ?1`,
  )
    .bind(version)
    .first<{
      package_r2_key: string;
      package_digest: string;
      is_revoked: number;
      revocation_reason: string | null;
    }>();

  if (!row) {
    return json(
      { error: `Agent release '${version}' not found` },
      { status: 404 },
    );
  }

  if (row.is_revoked) {
    return json(
      {
        error: `Agent release '${version}' has been revoked`,
        revocationReason: row.revocation_reason || "Security revocation",
      },
      { status: 410 },
    );
  }

  const bucket =
    (
      env as unknown as {
        CONCLAVE_STORAGE?: R2Bucket;
        CONCLAVE_PLUGINS?: R2Bucket;
      }
    ).CONCLAVE_STORAGE ??
    (
      env as unknown as {
        CONCLAVE_STORAGE?: R2Bucket;
        CONCLAVE_PLUGINS?: R2Bucket;
      }
    ).CONCLAVE_PLUGINS ??
    env.CONCLAVE_ARTIFACTS;
  if (!bucket) {
    return json({ error: "Storage bucket not configured" }, { status: 500 });
  }

  const object = await bucket.get(row.package_r2_key);
  if (!object) {
    return json(
      { error: "Agent package file not found in storage" },
      { status: 404 },
    );
  }

  const headers = new Headers();
  headers.set("Content-Type", "application/octet-stream");
  headers.set("content-digest", row.package_digest);
  headers.set("ETag", object.httpEtag);
  headers.set(
    "Content-Disposition",
    `attachment; filename="conclave-agent-${version}.tar.gz"`,
  );

  return new Response(object.body, { headers });
}

async function handlePublishAgentRelease(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(request, env, "workspace:manage", undefined, ctx);

  let version = "";
  let channel: "stable" | "beta" | "development" = "stable";
  let minSupportedAgentVersion: string | null = null;
  let supportedOS: string[] = ["macos", "linux", "windows"];
  let supportedArch: string[] = ["arm64", "x64"];
  let releaseNotes: string | null = null;
  let packageData: ArrayBuffer | null = null;
  let providedDigest: string | null = null;
  let providedSignature: string | null = null;

  const contentType = request.headers.get("content-type") || "";
  if (contentType.includes("multipart/form-data")) {
    const formData = await request.formData();
    const versionVal = formData.get("version");
    if (!versionVal || typeof versionVal !== "string") {
      return json({ error: "'version' is required" }, { status: 400 });
    }
    version = versionVal.trim();
    const chanVal = formData.get("channel");
    if (
      chanVal === "beta" ||
      chanVal === "development" ||
      chanVal === "stable"
    ) {
      channel = chanVal;
    }
    const minVer = formData.get("minSupportedAgentVersion");
    if (minVer && typeof minVer === "string") minSupportedAgentVersion = minVer;
    const osVal = formData.get("supportedOS");
    if (osVal && typeof osVal === "string") {
      supportedOS = parseJson<string[]>(osVal, supportedOS);
    }
    const archVal = formData.get("supportedArch");
    if (archVal && typeof archVal === "string") {
      supportedArch = parseJson<string[]>(archVal, supportedArch);
    }
    const notes = formData.get("releaseNotes");
    if (notes && typeof notes === "string") releaseNotes = notes;
    const dig = formData.get("packageDigest");
    if (dig && typeof dig === "string") providedDigest = dig;
    const sig = formData.get("signature");
    if (sig && typeof sig === "string") providedSignature = sig;

    const file = formData.get("package");
    if (file && typeof file === "object" && "arrayBuffer" in file) {
      packageData = await (file as Blob).arrayBuffer();
    }
  } else {
    const body = (await request.json().catch(() => ({}))) as Record<
      string,
      unknown
    >;
    if (!body.version || typeof body.version !== "string") {
      return json({ error: "'version' is required" }, { status: 400 });
    }
    version = body.version.trim();
    if (
      body.channel === "beta" ||
      body.channel === "development" ||
      body.channel === "stable"
    ) {
      channel = body.channel;
    }
    if (typeof body.minSupportedAgentVersion === "string") {
      minSupportedAgentVersion = body.minSupportedAgentVersion;
    }
    if (Array.isArray(body.supportedOS))
      supportedOS = body.supportedOS as string[];
    if (Array.isArray(body.supportedArch))
      supportedArch = body.supportedArch as string[];
    if (typeof body.releaseNotes === "string") releaseNotes = body.releaseNotes;
    if (typeof body.packageDigest === "string")
      providedDigest = body.packageDigest;
    if (typeof body.signature === "string") providedSignature = body.signature;
    if (typeof body.packageBase64 === "string") {
      packageData = Uint8Array.from(atob(body.packageBase64), (c) =>
        c.charCodeAt(0),
      ).buffer;
    }
  }

  if (!packageData) {
    return json(
      { error: "Package binary archive is required" },
      { status: 400 },
    );
  }

  const computedDigest = await computePackageDigest(packageData);
  if (providedDigest && providedDigest !== computedDigest) {
    return json(
      {
        error: `Package digest mismatch. Provided: ${providedDigest}, computed: ${computedDigest}`,
      },
      { status: 400 },
    );
  }
  const digest = computedDigest;

  const secretKey =
    env.CONCLAVE_AGENT_SIGNING_KEY ||
    (env as unknown as { CONCLAVE_SECURITY_KEY?: string })
      .CONCLAVE_SECURITY_KEY;
  if (!secretKey) {
    return json(
      { error: "Agent signing key is not configured" },
      { status: 503 },
    );
  }
  let signature: string;
  if (providedSignature) {
    const valid = await verifyPackageDigestSignature(
      digest,
      providedSignature,
      secretKey,
    );
    if (!valid) {
      return json({ error: "Invalid package signature" }, { status: 400 });
    }
    signature = providedSignature;
  } else {
    signature = await signPackageDigest(digest, secretKey);
  }

  const bucket =
    (
      env as unknown as {
        CONCLAVE_STORAGE?: R2Bucket;
        CONCLAVE_PLUGINS?: R2Bucket;
      }
    ).CONCLAVE_STORAGE ??
    (
      env as unknown as {
        CONCLAVE_STORAGE?: R2Bucket;
        CONCLAVE_PLUGINS?: R2Bucket;
      }
    ).CONCLAVE_PLUGINS ??
    env.CONCLAVE_ARTIFACTS;
  if (!bucket) {
    return json({ error: "Storage bucket not configured" }, { status: 500 });
  }

  const r2Key = `agent/releases/${version}/agent-${version}.tar.gz`;
  await bucket.put(r2Key, packageData, {
    httpMetadata: {
      contentType: "application/octet-stream",
    },
    customMetadata: {
      version,
      channel,
      packageDigest: digest,
      signature,
    },
  });

  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO agent_releases (
       version, channel, min_supported_agent_version, supported_os_json,
       supported_arch_json, package_digest, package_r2_key, signature,
       release_notes, is_revoked, created_at
     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 0, ?10)
     ON CONFLICT(version) DO UPDATE SET
       channel = excluded.channel,
       min_supported_agent_version = excluded.min_supported_agent_version,
       supported_os_json = excluded.supported_os_json,
       supported_arch_json = excluded.supported_arch_json,
       package_digest = excluded.package_digest,
       package_r2_key = excluded.package_r2_key,
       signature = excluded.signature,
       release_notes = excluded.release_notes,
       is_revoked = 0,
       revoked_at = NULL,
       revocation_reason = NULL`,
  )
    .bind(
      version,
      channel,
      minSupportedAgentVersion,
      JSON.stringify(supportedOS),
      JSON.stringify(supportedArch),
      digest,
      r2Key,
      signature,
      releaseNotes,
      now,
    )
    .run();

  return json(
    {
      version,
      channel,
      packageDigest: digest,
      packageR2Key: r2Key,
      signature,
      status: "published",
      publishedAt: now,
    },
    { status: 201 },
  );
}

async function handleRevokeAgentRelease(
  request: Request,
  env: SecurityEnv,
  version: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(request, env, "workspace:manage", undefined, ctx);

  const body = (await request.json().catch(() => ({}))) as { reason?: string };
  const reason = body.reason || "Revoked by administrator";
  const now = new Date().toISOString();

  await env.CONCLAVE_DB.prepare(
    `UPDATE agent_releases
     SET is_revoked = 1, revoked_at = ?1, revocation_reason = ?2
     WHERE version = ?3`,
  )
    .bind(now, reason, version)
    .run();

  return json({
    version,
    isRevoked: true,
    revokedAt: now,
    revocationReason: reason,
  });
}

export default {
  async fetch(
    request: Request,
    env: Env,
    ctx?: ExecutionContext,
  ): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true, environment: env.CONCLAVE_ENVIRONMENT });
    }

    try {
      if (request.method === "GET" && url.pathname === "/api/runtime/connect") {
        const securityEnv = env as SecurityEnv;
        runtimeToken(request, securityEnv, "CONCLAVE_RUNTIME_CONNECT_TOKEN");
        const runtimeId = runtimeConnectionId(request);
        const stub =
          securityEnv.CONCLAVE_RUNTIME_CONNECTION.getByName(runtimeId);
        return stub.fetch(request);
      }
      if (
        request.method === "POST" &&
        (url.pathname === "/api/runtime/operations" ||
          url.pathname === "/api/runtime/cancel" ||
          url.pathname === "/api/runtime/worker-execute")
      ) {
        const securityEnv = env as SecurityEnv;
        runtimeToken(request, securityEnv, "CONCLAVE_RUNTIME_OPERATION_TOKEN");
        const runtimeId = runtimeConnectionId(request);
        const stub =
          securityEnv.CONCLAVE_RUNTIME_CONNECTION.getByName(runtimeId);
        const target =
          url.pathname === "/api/runtime/cancel"
            ? "/cancel"
            : url.pathname === "/api/runtime/worker-execute"
              ? "/worker-execute"
              : "/execute";
        return stub.fetch(
          new Request(`https://runtime.internal${target}`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: await request.text(),
          }),
        );
      }
      if (request.method === "GET" && url.pathname === "/api/runtime/workers") {
        const securityEnv = env as SecurityEnv;
        runtimeToken(request, securityEnv, "CONCLAVE_RUNTIME_OPERATION_TOKEN");
        const runtimeId = runtimeConnectionId(request);
        const stub =
          securityEnv.CONCLAVE_RUNTIME_CONNECTION.getByName(runtimeId);
        return stub.fetch(new Request("https://runtime.internal/workers"));
      }
      const connectorMatch = url.pathname.match(
        /^\/api\/connector\/(register_session|claim_task|get_task|get_context|get_next_message|submit_candidate|submit_result|submit_finding|report_status|release_task)$/,
      );
      if (request.method === "POST" && connectorMatch?.[1]) {
        return await handleConnectorRequest(
          request,
          env as SecurityEnv,
          connectorMatch[1],
        );
      }
      if (
        request.method === "POST" &&
        url.pathname === "/api/connector/tasks/register"
      ) {
        return await handleConnectorTaskRequest(request, env, undefined);
      }
      const connectorTaskStatusMatch = url.pathname.match(
        /^\/api\/connector\/tasks\/([^/]+)\/status$/,
      );
      if (request.method === "GET" && connectorTaskStatusMatch?.[1]) {
        return await handleConnectorTaskRequest(
          request,
          env,
          connectorTaskStatusMatch[1],
        );
      }
      if (request.method === "GET" && url.pathname === "/api/workspaces") {
        return await handleListWorkspaces(request, env as SecurityEnv, ctx);
      }
      if (request.method === "POST" && url.pathname === "/api/workspaces") {
        return await handleCreateWorkspace(request, env as SecurityEnv, ctx);
      }
      const auditExportMatch = url.pathname.match(
        /^\/api\/workspaces\/([^/]+)\/audit-export$/,
      );
      if (request.method === "GET" && auditExportMatch?.[1]) {
        return await handleExportWorkspaceAudit(
          request,
          env as SecurityEnv,
          auditExportMatch[1],
          ctx,
        );
      }
      const backupMatch = url.pathname.match(
        /^\/api\/workspaces\/([^/]+)\/backup$/,
      );
      if (request.method === "POST" && backupMatch?.[1]) {
        return await handleCreateWorkspaceBackup(
          request,
          env as SecurityEnv,
          backupMatch[1],
          ctx,
        );
      }
      const backupRestoreDrillMatch = url.pathname.match(
        /^\/api\/workspaces\/([^/]+)\/backup\/restore-drill$/,
      );
      if (request.method === "POST" && backupRestoreDrillMatch?.[1]) {
        return await handleVerifyWorkspaceBackup(
          request,
          env as SecurityEnv,
          backupRestoreDrillMatch[1],
          ctx,
        );
      }
      const workspaceInvitationsMatch = url.pathname.match(
        /^\/api\/workspaces\/([^/]+)\/invitations$/,
      );
      if (workspaceInvitationsMatch?.[1]) {
        if (request.method === "GET") {
          return await handleListWorkspaceInvitations(
            request,
            env as SecurityEnv,
            workspaceInvitationsMatch[1],
            ctx,
          );
        }
        if (request.method === "POST") {
          return await handleCreateWorkspaceInvitation(
            request,
            env as SecurityEnv,
            workspaceInvitationsMatch[1],
            ctx,
          );
        }
      }
      const invitationExpireMatch = url.pathname.match(
        /^\/api\/workspaces\/([^/]+)\/invitations\/([^/]+)\/expire$/,
      );
      if (
        request.method === "POST" &&
        invitationExpireMatch?.[1] &&
        invitationExpireMatch[2]
      ) {
        return await handleExpireWorkspaceInvitation(
          request,
          env as SecurityEnv,
          invitationExpireMatch[1],
          invitationExpireMatch[2],
          ctx,
        );
      }
      const invitationAcceptMatch = url.pathname.match(
        /^\/api\/invitations\/([^/]+)\/accept$/,
      );
      if (request.method === "POST" && invitationAcceptMatch?.[1]) {
        return await handleAcceptWorkspaceInvitation(
          request,
          env as SecurityEnv,
          invitationAcceptMatch[1],
          ctx,
        );
      }
      const memberRoleMatch = url.pathname.match(
        /^\/api\/workspaces\/([^/]+)\/members\/([^/]+)\/role$/,
      );
      if (
        request.method === "PATCH" &&
        memberRoleMatch?.[1] &&
        memberRoleMatch[2]
      ) {
        return await handleChangeWorkspaceMemberRole(
          request,
          env as SecurityEnv,
          memberRoleMatch[1],
          memberRoleMatch[2],
          ctx,
        );
      }
      const memberStatusMatch = url.pathname.match(
        /^\/api\/workspaces\/([^/]+)\/members\/([^/]+)\/(suspend|remove|activate)$/,
      );
      if (
        request.method === "POST" &&
        memberStatusMatch?.[1] &&
        memberStatusMatch[2] &&
        memberStatusMatch[3]
      ) {
        const status =
          memberStatusMatch[3] === "suspend"
            ? "suspended"
            : memberStatusMatch[3] === "remove"
              ? "removed"
              : "active";
        return await handleWorkspaceMemberStatus(
          request,
          env as SecurityEnv,
          memberStatusMatch[1],
          memberStatusMatch[2],
          status,
          ctx,
        );
      }

      // Agent Gateway & Protocol routes
      if (
        request.method === "POST" &&
        url.pathname === "/api/internal/agent-assignments/dispatch"
      ) {
        return await handleInternalDispatchTaskAssignment(
          request,
          env as SecurityEnv,
        );
      }
      if (
        request.method === "GET" &&
        (url.pathname === "/api/agent-gateway/connect" ||
          url.pathname === "/api/v2/agent-gateway/connect")
      ) {
        return await handleAgentGatewayConnect(request, env as SecurityEnv);
      }
      if (
        request.method === "POST" &&
        (url.pathname === "/api/agent-protocol/messages" ||
          url.pathname === "/api/v2/agent-protocol/messages")
      ) {
        return await handleAgentProtocolMessage(request, env as SecurityEnv);
      }
      if (
        request.method === "POST" &&
        (url.pathname === "/api/agents/enroll" ||
          url.pathname === "/api/v2/agents/enroll")
      ) {
        return await handleEnrollAgent(request, env as SecurityEnv);
      }

      // Workspace Agent Enrollments
      const agentEnrollmentsMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/agent-enrollments$/,
      );
      if (request.method === "GET" && agentEnrollmentsMatch?.[1]) {
        return await handleListAgentEnrollments(
          request,
          env as SecurityEnv,
          agentEnrollmentsMatch[1],
          ctx,
        );
      }
      if (request.method === "POST" && agentEnrollmentsMatch?.[1]) {
        return await handleCreateAgentEnrollment(
          request,
          env as SecurityEnv,
          agentEnrollmentsMatch[1],
          ctx,
        );
      }
      const revokeEnrollmentMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/agent-enrollments\/([^/]+)$/,
      );
      if (
        request.method === "DELETE" &&
        revokeEnrollmentMatch?.[1] &&
        revokeEnrollmentMatch?.[2]
      ) {
        return await handleRevokeAgentEnrollment(
          request,
          env as SecurityEnv,
          revokeEnrollmentMatch[1],
          revokeEnrollmentMatch[2],
          ctx,
        );
      }

      // Workspace Agents Fleet
      const agentsMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/agents$/,
      );
      if (request.method === "GET" && agentsMatch?.[1]) {
        return await handleListAgents(
          request,
          env as SecurityEnv,
          agentsMatch[1],
          ctx,
        );
      }
      const singleAgentMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/agents\/([^/]+)$/,
      );
      if (
        request.method === "GET" &&
        singleAgentMatch?.[1] &&
        singleAgentMatch?.[2]
      ) {
        return await handleGetAgent(
          request,
          env as SecurityEnv,
          singleAgentMatch[1],
          singleAgentMatch[2],
          ctx,
        );
      }
      if (
        request.method === "DELETE" &&
        singleAgentMatch?.[1] &&
        singleAgentMatch?.[2]
      ) {
        return await handleRevokeAgent(
          request,
          env as SecurityEnv,
          singleAgentMatch[1],
          singleAgentMatch[2],
          ctx,
        );
      }

      // Workspace Workers Fleet (Architecture v2)
      const workersMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/workers$/,
      );
      if (request.method === "GET" && workersMatch?.[1]) {
        return await handleListWorkers(
          request,
          env as SecurityEnv,
          workersMatch[1],
          ctx,
        );
      }
      if (request.method === "POST" && workersMatch?.[1]) {
        return await handleCreateWorker(
          request,
          env as SecurityEnv,
          workersMatch[1],
          ctx,
        );
      }
      const singleWorkerMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/workers\/([^/]+)$/,
      );
      if (
        request.method === "GET" &&
        singleWorkerMatch?.[1] &&
        singleWorkerMatch?.[2]
      ) {
        return await handleGetWorker(
          request,
          env as SecurityEnv,
          singleWorkerMatch[1],
          singleWorkerMatch[2],
          ctx,
        );
      }
      if (
        request.method === "PUT" &&
        singleWorkerMatch?.[1] &&
        singleWorkerMatch?.[2]
      ) {
        return await handleUpdateWorker(
          request,
          env as SecurityEnv,
          singleWorkerMatch[1],
          singleWorkerMatch[2],
          ctx,
        );
      }
      if (
        request.method === "DELETE" &&
        singleWorkerMatch?.[1] &&
        singleWorkerMatch?.[2]
      ) {
        return await handleDeleteWorker(
          request,
          env as SecurityEnv,
          singleWorkerMatch[1],
          singleWorkerMatch[2],
          ctx,
        );
      }

      // Task Assignment Dispatcher (Architecture v2)
      const taskEnsembleDispatchMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/tasks\/([^/]+)\/ensemble-dispatch$/,
      );
      if (
        request.method === "POST" &&
        taskEnsembleDispatchMatch?.[1] &&
        taskEnsembleDispatchMatch?.[2]
      ) {
        return await handleDispatchEnsembleTaskAssignment(
          request,
          env as SecurityEnv,
          taskEnsembleDispatchMatch[1],
          taskEnsembleDispatchMatch[2],
          ctx,
        );
      }

      const taskDispatchMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/tasks\/([^/]+)\/dispatch$/,
      );
      if (
        request.method === "POST" &&
        taskDispatchMatch?.[1] &&
        taskDispatchMatch?.[2]
      ) {
        return await handleDispatchTaskAssignment(
          request,
          env as SecurityEnv,
          taskDispatchMatch[1],
          taskDispatchMatch[2],
          ctx,
        );
      }

      const assignmentCancelMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/workspaces\/([^/]+)\/assignments\/([^/]+)\/cancel$/,
      );
      if (
        request.method === "POST" &&
        assignmentCancelMatch?.[1] &&
        assignmentCancelMatch?.[2]
      ) {
        return await handleCancelTaskAssignment(
          request,
          env as SecurityEnv,
          assignmentCancelMatch[1],
          assignmentCancelMatch[2],
          ctx,
        );
      }

      // Plugin Registry routes (Architecture v2)
      if (
        request.method === "GET" &&
        (url.pathname === "/api/plugins" || url.pathname === "/api/v2/plugins")
      ) {
        return await handleListPlugins(request, env as SecurityEnv);
      }
      if (
        request.method === "POST" &&
        (url.pathname === "/api/plugins/publish" ||
          url.pathname === "/api/v2/plugins/publish")
      ) {
        return await handlePublishPlugin(request, env as SecurityEnv, ctx);
      }

      const pluginDownloadMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/plugins\/([^/]+)\/versions\/([^/]+)\/download$/,
      );
      if (
        request.method === "GET" &&
        pluginDownloadMatch?.[1] &&
        pluginDownloadMatch?.[2]
      ) {
        return await handleDownloadPluginVersion(
          request,
          env as SecurityEnv,
          pluginDownloadMatch[1],
          pluginDownloadMatch[2],
          ctx,
        );
      }

      const pluginRevokeMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/plugins\/([^/]+)\/versions\/([^/]+)\/revoke$/,
      );
      if (
        request.method === "POST" &&
        pluginRevokeMatch?.[1] &&
        pluginRevokeMatch?.[2]
      ) {
        return await handleRevokePluginVersion(
          request,
          env as SecurityEnv,
          pluginRevokeMatch[1],
          pluginRevokeMatch[2],
          ctx,
        );
      }

      const pluginVersionMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/plugins\/([^/]+)\/versions\/([^/]+)$/,
      );
      if (
        request.method === "GET" &&
        pluginVersionMatch?.[1] &&
        pluginVersionMatch?.[2]
      ) {
        return await handleGetPluginVersion(
          env as SecurityEnv,
          pluginVersionMatch[1],
          pluginVersionMatch[2],
        );
      }

      const pluginDeprecateMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/plugins\/([^/]+)\/deprecate$/,
      );
      if (request.method === "POST" && pluginDeprecateMatch?.[1]) {
        return await handleDeprecatePlugin(
          request,
          env as SecurityEnv,
          pluginDeprecateMatch[1],
          ctx,
        );
      }

      const singlePluginMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/plugins\/([^/]+)$/,
      );
      if (request.method === "GET" && singlePluginMatch?.[1]) {
        return await handleGetPlugin(env as SecurityEnv, singlePluginMatch[1]);
      }

      // Agent Releases routes (Architecture v2 Self-Update)
      if (
        request.method === "GET" &&
        (url.pathname === "/api/agent-releases/latest" ||
          url.pathname === "/api/v2/agent-releases/latest")
      ) {
        return await handleGetLatestAgentRelease(request, env as SecurityEnv);
      }
      if (
        request.method === "POST" &&
        (url.pathname === "/api/agent-releases/publish" ||
          url.pathname === "/api/v2/agent-releases/publish")
      ) {
        return await handlePublishAgentRelease(
          request,
          env as SecurityEnv,
          ctx,
        );
      }
      const agentReleaseDownloadMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/agent-releases\/([^/]+)\/download$/,
      );
      if (request.method === "GET" && agentReleaseDownloadMatch?.[1]) {
        return await handleDownloadAgentRelease(
          request,
          env as SecurityEnv,
          agentReleaseDownloadMatch[1],
          ctx,
        );
      }
      const agentReleaseRevokeMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/agent-releases\/([^/]+)\/revoke$/,
      );
      if (request.method === "POST" && agentReleaseRevokeMatch?.[1]) {
        return await handleRevokeAgentRelease(
          request,
          env as SecurityEnv,
          agentReleaseRevokeMatch[1],
          ctx,
        );
      }
      const singleAgentReleaseMatch = url.pathname.match(
        /^\/api(?:\/v2)?\/agent-releases\/([^/]+)$/,
      );
      if (request.method === "GET" && singleAgentReleaseMatch?.[1]) {
        return await handleGetAgentRelease(
          env as SecurityEnv,
          singleAgentReleaseMatch[1],
        );
      }

      const workspaceMatch = url.pathname.match(/^\/api\/workspaces\/([^/]+)$/);
      if (request.method === "GET" && workspaceMatch?.[1]) {
        return await handleGetWorkspace(
          request,
          env as SecurityEnv,
          workspaceMatch[1],
          ctx,
        );
      }

      if (request.method === "GET" && url.pathname === "/api/projects") {
        return await handleListProjects(request, env as SecurityEnv, ctx);
      }
      if (request.method === "POST" && url.pathname === "/api/projects") {
        return await handleCreateProject(request, env as SecurityEnv, ctx);
      }
      const projectChatsMatch = url.pathname.match(
        /^\/api\/projects\/([^/]+)\/chats$/,
      );
      if (request.method === "GET" && projectChatsMatch?.[1]) {
        return await handleListChats(
          request,
          env as SecurityEnv,
          projectChatsMatch[1],
          ctx,
        );
      }
      if (request.method === "POST" && projectChatsMatch?.[1]) {
        return await handleCreateChat(
          request,
          env as SecurityEnv,
          projectChatsMatch[1],
          ctx,
        );
      }
      const projectMatch = url.pathname.match(/^\/api\/projects\/([^/]+)$/);
      if (request.method === "GET" && projectMatch?.[1]) {
        return await handleGetProject(
          request,
          env as SecurityEnv,
          projectMatch[1],
          ctx,
        );
      }

      const chatGoalsMatch = url.pathname.match(
        /^\/api\/chats\/([^/]+)\/goals$/,
      );
      if (request.method === "GET" && chatGoalsMatch?.[1]) {
        return await handleListChatGoals(
          request,
          env as SecurityEnv,
          chatGoalsMatch[1],
          ctx,
        );
      }
      const chatMessagesMatch = url.pathname.match(
        /^\/api\/chats\/([^/]+)\/messages$/,
      );
      if (request.method === "GET" && chatMessagesMatch?.[1]) {
        return await handleListChatMessages(
          request,
          env as SecurityEnv,
          chatMessagesMatch[1],
          ctx,
        );
      }
      if (request.method === "POST" && chatMessagesMatch?.[1]) {
        return await handleCreateChatMessage(
          request,
          env as SecurityEnv,
          chatMessagesMatch[1],
          ctx,
        );
      }
      const chatMatch = url.pathname.match(/^\/api\/chats\/([^/]+)$/);
      if (request.method === "GET" && chatMatch?.[1]) {
        return await handleGetChat(
          request,
          env as SecurityEnv,
          chatMatch[1],
          ctx,
        );
      }
      if (request.method === "PATCH" && chatMatch?.[1]) {
        return await handleUpdateChat(
          request,
          env as SecurityEnv,
          chatMatch[1],
          ctx,
        );
      }

      if (request.method === "POST" && url.pathname === "/api/runs") {
        return await handleRunRequest(request, env, ctx);
      }
      if (request.method === "POST" && url.pathname === "/api/goals") {
        return await handleGoalRequest(request, env, ctx);
      }
      if (request.method === "GET" && url.pathname === "/api/studio/snapshot") {
        return await handleStudioSnapshot(
          env,
          request,
          url.searchParams.get("projectId"),
          ctx,
        );
      }
      const runMatch = url.pathname.match(
        /^\/api\/runs\/([^/]+)(?:\/(pause|resume|restart|cancel|events|ci-evidence|forge-events))?$/,
      );
      if (runMatch?.[1] && request.method === "GET" && !runMatch[2]) {
        const securityEnv = env as SecurityEnv;
        const projectId = anonymousDevelopment(securityEnv)
          ? undefined
          : await runProjectId(securityEnv, runMatch[1]);
        await authorizeRequest(
          request,
          securityEnv,
          "project:read",
          projectId,
          ctx,
        );
        const workflowInstanceId = await resolveWorkflowInstanceId(
          env,
          runMatch[1],
        );
        const instance =
          await env.CONCLAVE_RUN_WORKFLOW.get(workflowInstanceId);
        return json({
          id: runMatch[1],
          workflowInstanceId,
          ...(await instance.status()),
        });
      }
      if (runMatch?.[1] && request.method === "POST" && runMatch[2]) {
        const command =
          runMatch[2] === "events"
            ? "event"
            : runMatch[2] === "ci-evidence"
              ? "ci-evidence"
              : runMatch[2] === "forge-events"
                ? "forge-terminal"
                : (runMatch[2] as "pause" | "resume" | "restart" | "cancel");
        return await handleRunCommand(request, env, runMatch[1], command, ctx);
      }
    } catch (error) {
      return json(
        { error: errorMessage(error) },
        {
          status:
            error instanceof HttpError ||
            (typeof error === "object" &&
              error !== null &&
              "status" in error &&
              typeof error.status === "number")
              ? (error as { status: number }).status
              : 400,
        },
      );
    }

    return json({ error: "not_found" }, { status: 404 });
  },
} satisfies ExportedHandler<Env>;
