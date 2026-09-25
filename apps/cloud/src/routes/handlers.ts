export { ConclaveRunWorkflow } from "../workflow.js";
export { WorkspaceGateway } from "../workspace-gateway.js";
export {
  selectWorkerForTask,
  dispatchTaskAssignment,
  recordAssignmentResult,
  recordAssignmentError,
  cancelTaskAssignment,
  type TaskToDispatch,
  type AssignmentDispatcherEnv,
} from "../assignment-dispatcher.js";
export {
  selectEnsembleCandidateWorkers,
  dispatchEnsembleTaskAssignment,
  type EnsembleDispatchParams,
  type SelectedEnsembleWorker,
} from "../ensemble-dispatcher.js";
export { handleConnectorRequest } from "../interactive-connector.js";
import { handleConnectorTaskRequest } from "../interactive-connector.js";
import { isTrustedOrigin } from "../observability.js";
import {
  identityService,
  handleBetterAuthRequest,
  listPendingInvitations,
  provisionConclaveUser,
  hasRecentStepUp,
  SENSITIVE_OPERATIONS,
  recordAuthAuditEvent,
  type SensitiveOperation,
} from "../auth/index.js";
import {
  dispatchTaskAssignment,
  cancelTaskAssignment,
  type TaskToDispatch,
  type AssignmentDispatcherEnv,
} from "../assignment-dispatcher.js";
import {
  dispatchEnsembleTaskAssignment,
  type EnsembleDispatchParams,
} from "../ensemble-dispatcher.js";
import {
  authorize,
  authorizeHostWorkspaceAction,
  extractBearerToken,
  hashToken,
  computePackageDigest,
  signPackageDigest,
  verifyPackageDigestSignature,
  resolveProjectSecurityContextFromIdentity,
  resolveSecurityContextFromIdentity,
  authorizeProjectMembership,
  authorizeWorkspaceOwner,
  authorizeProjectOwner,
  authorizeProjectAccountUse,
  authorizeCredentialProfileUse,
  type Permission,
  type SecurityContext,
} from "@conclave/security";
import {
  validateWorkerManifest,
  compareSemver,
} from "@conclave/worker-manifest";
import {
  AGENT_PROTOCOL_NAME,
  AGENT_PROTOCOL_VERSION,
  parseAgentMessage,
  type AgentProtocolMessage,
} from "@conclave/host-protocol";
import {
  validateWorkspace,
  validateProject,
  validateChat,
  validateChatMessage,
  type Workspace,
  type Project,
  type Chat,
  type ChatMessage,
  type ChatMessageSenderType,
  type ChatMessageKind,
  assembleChatContext,
  validateWorkRequest,
  validateWorkflowVersion,
  canDiscussWorkstream,
  canExecuteWorkstream,
  canManageWorkstream,
  canViewWorkstream,
  DEFAULT_WORKSTREAM_ACCESS_POLICY,
  type WorkRequest,
  type ProjectMembership,
  type Workstream,
  type WorkstreamExecutionPolicy,
  type WorkflowVersion,
} from "@conclave/core";
import { parseMachineCheckEvidence } from "@conclave/protocol";
import { createEventPublisher } from "../event-publisher.js";

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
  resourceWorkspaceId?: string,
): Promise<void> {
  const auditWorkspaceId = resourceWorkspaceId ?? context.workspaceId;
  const values = [
    `audit-${crypto.randomUUID()}`,
    auditWorkspaceId,
    context.userId,
    action,
    targetType,
    targetId,
    JSON.stringify(details),
    new Date().toISOString(),
  ] as const;
  try {
    await env.CONCLAVE_DB.prepare(
      `INSERT INTO audit_log
         (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (?1, ?2, 'user', ?3, ?4, ?5, ?6, ?7, ?8)`,
    )
      .bind(...values)
      .run();
  } catch {
    await env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_audit_log
         (id, workspace_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (?1, ?2, 'user', ?3, ?4, ?5, ?6, ?7, ?8)`,
    )
      .bind(...values)
      .run();
  }
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
  readonly BETTER_AUTH_SECRET?: string;
  readonly BETTER_AUTH_URL?: string;
  readonly CONCLAVE_AUTH_GITHUB_CLIENT_ID?: string;
  readonly CONCLAVE_AUTH_GITHUB_CLIENT_SECRET?: string;
  readonly CONCLAVE_AUTH_GOOGLE_CLIENT_ID?: string;
  readonly CONCLAVE_AUTH_GOOGLE_CLIENT_SECRET?: string;
  readonly CONCLAVE_PLUGIN_PUBLISHER_EMAIL?: string;
  readonly CONCLAVE_PLUGIN_SIGNING_KEY?: string;
  readonly CONCLAVE_HOST_SIGNING_KEY?: string;
  readonly CONCLAVE_SECURITY_KEY?: string;
  readonly TEST_AUTHENTICATION?: (
    request: Request,
    env: Env,
  ) => Promise<SecurityContext>;
  readonly CONCLAVE_CI_INGEST_TOKEN?: string;
  readonly CONCLAVE_FORGE_CALLBACK_TOKEN?: string;
  readonly CONCLAVE_WORKSPACE_GATEWAY?: DurableObjectNamespace;
  readonly CONCLAVE_REALTIME_GATEWAY?: DurableObjectNamespace;
  readonly CONCLAVE_WORKSTREAM_COORDINATOR?: DurableObjectNamespace;
  readonly CONCLAVE_CONNECTOR_REGISTRATION_TOKEN?: string;
};

function testAuthenticationEnabled(env: Env): boolean {
  return (
    env.CONCLAVE_ENVIRONMENT === "development" &&
    typeof (env as SecurityEnv).TEST_AUTHENTICATION === "function"
  );
}

function bearer(request: Request): string | null {
  const value = request.headers.get("authorization");
  return value?.startsWith("Bearer ") ? value.slice(7) : null;
}

export function requireSameOriginForCookieMutation(request: Request): void {
  if (!request.headers.get("cookie") || bearer(request)) return;

  const requestOrigin = new URL(request.url).origin;
  const origin = request.headers.get("origin");
  if (origin === requestOrigin || (origin && isTrustedOrigin(request))) return;

  const referer = request.headers.get("referer");
  if (origin === null && referer) {
    try {
      if (new URL(referer).origin === requestOrigin) return;
      const refUrl = new URL(referer);
      if (
        refUrl.hostname === "localhost" ||
        refUrl.hostname === "127.0.0.1" ||
        refUrl.hostname === "[::1]"
      ) {
        return;
      }
    } catch {
      // Treat malformed referers as untrusted.
    }
  }

  throw new HttpError(403, "Same-origin request required for cookie session");
}

async function securityContext(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<SecurityContext> {
  // Preserve the route-handler context contract for callers that also use it
  // for non-authentication infrastructure; human identity never comes from it.
  void accessContext;
  const testAuthentication = env.TEST_AUTHENTICATION;
  if (
    env.CONCLAVE_ENVIRONMENT === "development" &&
    typeof testAuthentication === "function"
  ) {
    return testAuthentication(request, env);
  }
  if (env.BETTER_AUTH_SECRET) {
    const identity = await identityService.resolve(request, env);
    if (!identity) throw new HttpError(401, "Authentication required");
    try {
      await provisionConclaveUser(env.CONCLAVE_DB, identity);
      const requestedWorkspaceId =
        request.headers.get("x-conclave-workspace-id")?.trim() || undefined;
      if (requestedWorkspaceId) {
        try {
          return await resolveSecurityContextFromIdentity(
            env.CONCLAVE_DB,
            identity,
            { requestedWorkspaceId },
          );
        } catch {
          // Fall back to project security context if requested workspace is invalid/not found
        }
      }
      return await resolveProjectSecurityContextFromIdentity(
        env.CONCLAVE_DB,
        identity,
      );
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

  throw new HttpError(401, "Better Auth authentication required");
}

async function authorizeRequest(
  request: Request,
  env: SecurityEnv,
  permission: Permission,
  projectId?: string,
  accessContext?: ExecutionContext,
): Promise<SecurityContext> {
  const context = await securityContext(request, env, accessContext);
  if (projectId && !testAuthenticationEnabled(env)) {
    if (context.authorizationModel === "v5") {
      try {
        await authorizeProjectMembership(
          env.CONCLAVE_DB,
          context,
          projectId,
          permission,
        );
      } catch {
        throw new HttpError(404, "Resource not found");
      }
    } else {
      const project = await env.CONCLAVE_DB.prepare(
        "SELECT workspace_id FROM projects WHERE id = ?1",
      )
        .bind(projectId)
        .first<{
          workspace_id?: string | null;
        }>();
      const ownerWorkspace = project?.workspace_id;
      if (!project || ownerWorkspace !== context.workspaceId) {
        await recordAuthAuditEvent(env.CONCLAVE_DB, {
          action: "auth.authorization.denied",
          outcome: "denied",
          userId: context.userId,
          sessionId: context.sessionId,
          workspaceId: context.workspaceId,
          reason: "invalid_project",
        }).catch(() => undefined);
        throw new HttpError(404, "Resource not found");
      }
    }
  }
  try {
    authorize(context, permission, projectId);
  } catch (error) {
    await recordAuthAuditEvent(env.CONCLAVE_DB, {
      action: "auth.authorization.denied",
      outcome: "denied",
      userId: context.userId,
      sessionId: context.sessionId,
      workspaceId: context.workspaceId,
      reason: "not_authorized",
      operation: permission,
    }).catch(() => undefined);
    throw new HttpError(
      403,
      error instanceof Error ? error.message : "Forbidden",
    );
  }
  return context;
}

async function requireWorkspaceContext(
  context: SecurityContext,
  env: SecurityEnv,
  workspaceId: string,
): Promise<void> {
  // v5/v6 Workspaces are user-owned execution resources, not the active
  // browser tenant. The requested resource must be checked by ownership;
  // comparing it with the legacy session workspace would reject a newly
  // created Workspace before its first enrollment.
  if (context.authorizationModel === "v5") {
    await authorizeWorkspaceOwner(
      env.CONCLAVE_DB,
      context,
      workspaceId,
      "workspace:manage",
    );
    return;
  }
  if (!testAuthenticationEnabled(env) && context.workspaceId !== workspaceId) {
    throw new HttpError(404, "Resource not found");
  }
}

async function requireRecentStepUp(
  env: SecurityEnv,
  context: SecurityContext,
  operation: SensitiveOperation,
): Promise<void> {
  const satisfied = await hasRecentStepUp(
    env.CONCLAVE_DB,
    context.userId,
    context.sessionId,
    operation,
  );
  if (!satisfied) {
    throw new HttpError(428, "Fresh strong authentication required");
  }
}

function requireCiAuthentication(request: Request, env: SecurityEnv): void {
  const configuredToken = env.CONCLAVE_CI_INGEST_TOKEN;
  if (testAuthenticationEnabled(env) && !configuredToken) return;
  if (!configuredToken || bearer(request) !== configuredToken)
    throw new HttpError(401, "CI evidence authentication required");
}

function requireForgeCallbackAuthentication(
  request: Request,
  env: SecurityEnv,
): void {
  if (testAuthenticationEnabled(env) && !env.CONCLAVE_FORGE_CALLBACK_TOKEN)
    return;
  if (
    !env.CONCLAVE_FORGE_CALLBACK_TOKEN ||
    bearer(request) !== env.CONCLAVE_FORGE_CALLBACK_TOKEN
  ) {
    throw new HttpError(401, "Forge callback authentication required");
  }
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

type ConclaveWorkflowParams = import("../workflow.js").ConclaveWorkflowParams;

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
    "run.start",
    undefined,
    accessContext,
  );
  const projectId = testAuthenticationEnabled(securityEnv)
    ? undefined
    : await goalProjectId(securityEnv, goalId);
  await authorizeRequest(
    request,
    securityEnv,
    "run.start",
    projectId,
    accessContext,
  );
  const requestedAccountId =
    typeof body.accountId === "string"
      ? body.accountId
      : typeof body.credentialProfileId === "string"
        ? body.credentialProfileId
        : null;
  if (context.authorizationModel === "v5" && requestedAccountId && projectId) {
    await authorizeProjectAccountUse(
      securityEnv.CONCLAVE_DB,
      context,
      projectId,
      requestedAccountId,
    );
  } else if (requestedAccountId) {
    await authorizeCredentialProfileUse(
      securityEnv.CONCLAVE_DB,
      context,
      requestedAccountId,
    );
  }
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
  let workflowVersion: WorkflowVersion | undefined;
  const workflowVersionValue = body.workflowVersionSnapshot ?? body.workflowVersion;
  if (workflowVersionValue && typeof workflowVersionValue === "object") {
    try {
      workflowVersion = workflowVersionValue as WorkflowVersion;
      validateWorkflowVersion(workflowVersion);
    } catch (error) {
      throw new HttpError(
        400,
        error instanceof Error ? error.message : "Invalid WorkflowVersion",
      );
    }
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
    ...(typeof body.workRequestId === "string"
      ? { workRequestId: body.workRequestId }
      : {}),
    ...(body.input && typeof body.input === "object"
      ? { input: body.input as Record<string, unknown> }
      : {}),
    ...(workflowVersion ? { workflowVersion } : {}),
  };
  const run = await createOrGetRun(env, params);
  try {
    await createEventPublisher(securityEnv).publish({
      type: "run.started",
      workspaceId: context.workspaceId,
      projectId,
      runId: params.runId,
      idempotencyKey: `run:${params.runId}:started`,
      payload: { entityId: params.runId, status: String(run.status) },
    });
  } catch (error) {
    console.error("Failed to publish run.started", error);
  }
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

  if (chatId && !testAuthenticationEnabled(securityEnv)) {
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
      null,
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

async function handleSession(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const pendingInvitations = await listPendingInvitations(
    env.CONCLAVE_DB,
    context.user.email,
  );
  return json({
    authenticated: true,
    user: context.user,
    workspaceId: context.workspaceId,
    workspaceRole: context.workspaceRole,
    sessionId: context.sessionId,
    clientType: context.clientType,
    pendingInvitations,
  });
}

async function handleListPendingInvitations(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  return json({
    invitations: await listPendingInvitations(
      env.CONCLAVE_DB,
      context.user.email,
    ),
  });
}

async function handleSessionLogout(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const headers = new Headers(request.headers);
  headers.delete("content-length");
  headers.set("content-type", "application/json");
  const authRequest = new Request(new URL("/api/auth/sign-out", request.url), {
    method: "POST",
    headers,
    body: JSON.stringify({ disableRedirect: true }),
  });
  const response = await handleBetterAuthRequest(authRequest, env);
  if (response.ok && env.CONCLAVE_DB) {
    await recordAudit(env, context, "logout", "session", context.sessionId);
  }
  return response;
}

/** Complete the browser passkey ceremony as a session-bound step-up proof. */
async function handleCompleteStepUp(
  request: Request,
  env: SecurityEnv,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const event = await env.CONCLAVE_DB.prepare(
    `SELECT id, method FROM auth_step_up_events
     WHERE user_id = ?1 AND consumed_at IS NULL
     ORDER BY created_at DESC LIMIT 1`,
  )
    .bind(context.userId)
    .first<{ id: string; method: "passkey" | "totp" }>();
  if (!event) {
    return json(
      { error: "No recent strong authentication ceremony is available" },
      { status: 428 },
    );
  }

  const now = new Date();
  const authenticatedAt = now.toISOString();
  const expiresAt = new Date(now.getTime() + 10 * 60 * 1000).toISOString();
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `INSERT INTO auth_step_up_sessions
           (id, user_id, session_id, method, authenticated_at, expires_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(session_id) DO UPDATE SET
           method = excluded.method,
           authenticated_at = excluded.authenticated_at,
           expires_at = excluded.expires_at`,
    ).bind(
      crypto.randomUUID(),
      context.userId,
      context.sessionId,
      event.method,
      authenticatedAt,
      expiresAt,
    ),
    env.CONCLAVE_DB.prepare(
      "UPDATE auth_step_up_events SET consumed_at = ?1 WHERE id = ?2 AND consumed_at IS NULL",
    ).bind(authenticatedAt, event.id),
  ]);
  await recordAuthAuditEvent(env.CONCLAVE_DB, {
    action: "auth.step_up.completed",
    outcome: "success",
    userId: context.userId,
    sessionId: context.sessionId,
    provider: event.method,
    operation: "step_up",
  });
  return json({ ok: true, method: event.method, expiresAt });
}

async function handleListWorkspaces(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  if (testAuthenticationEnabled(env)) {
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
  const rows =
    context.authorizationModel === "v5"
      ? await env.CONCLAVE_DB.prepare(
          `SELECT id, name, status, 'owner' AS role,
                  created_at AS createdAt, updated_at AS updatedAt
           FROM execution_workspaces
           WHERE owner_user_id = ?1
           ORDER BY name ASC`,
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
          }>()
          .catch(() => ({ results: [] }))
      : await env.CONCLAVE_DB.prepare(
          `SELECT w.id, w.name, w.status, wm.role,
                  w.created_at AS createdAt, w.updated_at AS updatedAt
           FROM workspaces w
           JOIN workspace_memberships wm ON wm.workspace_id = w.id
           WHERE wm.user_id = ?1
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
          }>()
          .catch(() => ({ results: [] }));
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
      "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?1, ?2, ?3, 'enrolled', ?4, ?4)",
    ).bind(id, context.userId, name, now),
  ]);

  return json(
    { workspace: { ...workspace, status: "enrolled", role: "owner" } },
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
  if (context.workspaceId !== workspaceId && !testAuthenticationEnabled(env)) {
    const membership = await env.CONCLAVE_DB.prepare(
      "SELECT role FROM workspace_memberships WHERE workspace_id = ?1 AND user_id = ?2 AND status = 'active'",
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

async function handleUpdateWorkspace(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await workspaceMemberContext(
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
    "UPDATE workspaces SET name = ?1, updated_at = ?2 WHERE id = ?3 AND status = 'active'",
  )
    .bind(name, now, workspaceId)
    .run();
  if (!result.success) throw new HttpError(404, "Workspace not found");
  await recordAudit(
    env,
    context,
    "workspace.updated",
    "workspace",
    workspaceId,
    {
      name,
    },
  );
  return json({ workspace: { id: workspaceId, name, updatedAt: now } });
}

async function handleListWorkspaceMembers(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await workspaceMemberContext(
    request,
    env,
    workspaceId,
    "host.view",
    accessContext,
  );
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT wm.user_id AS userId, u.display_name AS displayName, u.email,
            wm.role, wm.status, wm.created_at AS createdAt,
            wm.updated_at AS updatedAt
     FROM workspace_memberships wm
     JOIN users u ON u.id = wm.user_id
     WHERE wm.workspace_id = ?1
     ORDER BY CASE wm.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END,
              u.display_name ASC`,
  )
    .bind(workspaceId)
    .all();
  return json({ members: rows.results ?? [] });
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
  { name: "hosts", sql: "SELECT * FROM hosts WHERE workspace_id = ?1" },
  {
    name: "host_enrollments",
    sql: "SELECT * FROM host_enrollments WHERE workspace_id = ?1",
  },
  {
    name: "host_sessions",
    sql: "SELECT * FROM host_sessions WHERE workspace_id = ?1",
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
];

const MAX_ARTIFACT_UPLOAD_BYTES = 64 * 1024 * 1024;

function artifactName(value: string | null): string {
  const normalized = (value ?? "artifact").replace(/[^a-zA-Z0-9._-]/g, "_");
  return normalized.slice(0, 160) || "artifact";
}

function artifactMetadata(
  row: Record<string, unknown>,
): Record<string, unknown> {
  const provenance = parseJson<Record<string, unknown>>(
    row.provenance_json,
    {},
  );
  return {
    id: String(row.id),
    workspaceId: String(row.workspace_id),
    projectId: String(row.project_id),
    runId: String(row.run_id),
    ...(row.task_id ? { taskId: String(row.task_id) } : {}),
    ...(row.attempt_id ? { attemptId: String(row.attempt_id) } : {}),
    mediaType: String(row.media_type),
    contentDigest: String(row.content_digest),
    sizeBytes: Number(row.size_bytes),
    name: artifactName(
      typeof provenance.name === "string" ? provenance.name : null,
    ),
    storage: "artifact-service",
    downloadUrl: `/api/artifacts/${encodeURIComponent(String(row.id))}?workspaceId=${encodeURIComponent(String(row.workspace_id))}`,
    createdAt: String(row.created_at),
  };
}

async function handleUploadArtifact(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const url = new URL(request.url);
  const projectId = url.searchParams.get("projectId");
  const runId = url.searchParams.get("runId");
  const taskId = url.searchParams.get("taskId");
  const attemptId = url.searchParams.get("attemptId");
  const assignmentId = url.searchParams.get("assignmentId");
  if (!projectId || !runId) {
    throw new HttpError(400, "projectId and runId are required");
  }
  const context = await workspaceMemberContext(
    request,
    env,
    workspaceId,
    "project:read",
    accessContext,
  );
  const scope = await env.CONCLAVE_DB.prepare(
    `SELECT p.workspace_id AS workspaceId
       FROM projects p JOIN runs r ON r.project_id = p.id
      WHERE p.id = ?1 AND r.id = ?2 AND p.workspace_id = ?3`,
  )
    .bind(projectId, runId, workspaceId)
    .first<{ workspaceId: string }>();
  if (!scope) throw new HttpError(404, "Artifact scope not found");
  const lengthHeader = request.headers.get("content-length");
  const declaredLength = lengthHeader ? Number(lengthHeader) : null;
  if (
    declaredLength !== null &&
    (!Number.isSafeInteger(declaredLength) ||
      declaredLength > MAX_ARTIFACT_UPLOAD_BYTES)
  ) {
    throw new HttpError(413, "Artifact exceeds the 64 MiB upload limit");
  }
  const artifactId =
    url.searchParams.get("artifactId") ??
    request.headers.get("x-artifact-id") ??
    `artifact-${crypto.randomUUID()}`;
  const existing = await env.CONCLAVE_DB.prepare(
    "SELECT * FROM artifacts WHERE id = ?1",
  )
    .bind(artifactId)
    .first<Record<string, unknown>>();
  if (existing) {
    if (String(existing.workspace_id) !== workspaceId) {
      throw new HttpError(409, "Artifact upload identity is already in use");
    }
    return json({ artifact: artifactMetadata(existing), deduplicated: true });
  }
  const body = await request.arrayBuffer();
  if (body.byteLength > MAX_ARTIFACT_UPLOAD_BYTES) {
    throw new HttpError(413, "Artifact exceeds the 64 MiB upload limit");
  }
  const mediaType =
    request.headers.get("content-type")?.split(";", 1)[0]?.trim() ||
    "application/octet-stream";
  const name = artifactName(
    url.searchParams.get("name") ?? request.headers.get("x-artifact-name"),
  );
  const computedDigest = await computePackageDigest(body);
  const suppliedDigest = request.headers.get("x-content-digest");
  if (suppliedDigest && suppliedDigest !== computedDigest) {
    throw new HttpError(422, "Artifact content digest does not match payload");
  }
  const digest = suppliedDigest ?? computedDigest;
  const storageKey = `artifact-objects/${workspaceId}/${crypto.randomUUID()}`;
  const bucket = env.CONCLAVE_ARTIFACTS;
  if (!bucket) throw new HttpError(503, "Artifact storage is not configured");
  await bucket.put(storageKey, body, {
    httpMetadata: { contentType: mediaType },
    customMetadata: { artifactId, workspaceId, digest },
  });
  const now = new Date().toISOString();
  try {
    await env.CONCLAVE_DB.prepare(
      `INSERT INTO artifacts
       (id, workspace_id, project_id, run_id, task_id, attempt_id, assignment_id,
        media_type, content_digest, storage_kind, storage_key, inline_content,
        size_bytes, provenance_json, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'r2', ?10, NULL, ?11, ?12, ?13)`,
    )
      .bind(
        artifactId,
        workspaceId,
        projectId,
        runId,
        taskId,
        attemptId,
        assignmentId,
        mediaType,
        digest,
        storageKey,
        body.byteLength,
        JSON.stringify({ name }),
        now,
      )
      .run();
  } catch (error) {
    await bucket.delete(storageKey).catch(() => undefined);
    throw error;
  }
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT * FROM artifacts WHERE id = ?1",
  )
    .bind(artifactId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(500, "Artifact record was not created");
  await createEventPublisher(env).publish({
    type: "artifact.created",
    workspaceId,
    projectId,
    runId,
    taskId: taskId ?? undefined,
    assignmentId: assignmentId ?? undefined,
    payload: {
      artifactId,
      entityId: artifactId,
      status: "available",
      summary: `${name} is ready to download`,
    },
  });
  await recordAudit(env, context, "artifact.created", "artifact", artifactId, {
    projectId,
    runId,
    sizeBytes: body.byteLength,
    mediaType,
  });
  return json({ artifact: artifactMetadata(row) }, { status: 201 });
}

async function handleGetArtifact(
  request: Request,
  env: SecurityEnv,
  artifactId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT * FROM artifacts WHERE id = ?1",
  )
    .bind(artifactId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Artifact not found");
  const context = await authorizeRequest(
    request,
    env,
    "project:read",
    String(row.project_id),
    accessContext,
  );
  if (context.workspaceId !== String(row.workspace_id)) {
    throw new HttpError(404, "Artifact not found");
  }
  if (request.method === "HEAD") {
    return new Response(null, {
      status: 200,
      headers: {
        "content-type": String(row.media_type),
        "content-length": String(row.size_bytes),
      },
    });
  }
  if (row.storage_kind === "inline") {
    return new Response(String(row.inline_content ?? ""), {
      headers: { "content-type": String(row.media_type) },
    });
  }
  const object = await env.CONCLAVE_ARTIFACTS.get(String(row.storage_key));
  if (!object) throw new HttpError(404, "Artifact content not found");
  const provenance = parseJson<Record<string, unknown>>(
    row.provenance_json,
    {},
  );
  return new Response(object.body, {
    headers: {
      "content-type": String(row.media_type),
      "content-length": String(row.size_bytes),
      "content-disposition": `inline; filename="${artifactName(typeof provenance.name === "string" ? provenance.name : null)}"`,
      "cache-control": "private, no-store",
    },
  });
}

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
  if (context.authorizationModel === "v5") {
    await authorizeWorkspaceOwner(
      env.CONCLAVE_DB,
      context,
      workspaceId,
      permission,
    ).catch((error: unknown) => {
      throw new HttpError(
        404,
        error instanceof Error ? "Workspace not found" : "Workspace not found",
      );
    });
    return context;
  }
  if (!testAuthenticationEnabled(env) && context.workspaceId !== workspaceId) {
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
  await recordAuthAuditEvent(env.CONCLAVE_DB, {
    action: "auth.invitation.accepted",
    outcome: "success",
    userId: context.userId,
    workspaceId: invitation.workspaceId,
  });
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
  if (context.authorizationModel === "v5") {
    const rows = await env.CONCLAVE_DB.prepare(
      `SELECT p.id, p.name, p.description, p.repository_id AS repositoryId,
              p.settings_json AS settingsJson, p.created_at AS createdAt, p.updated_at AS updatedAt
       FROM projects p
       JOIN project_memberships pm ON pm.project_id = p.id
       WHERE pm.user_id = ?1
         AND COALESCE(json_extract(p.settings_json, '$.archived'), 0) = 0
       ORDER BY p.updated_at DESC`,
    )
      .bind(context.userId)
      .all<{
        id: string;
        name: string;
        description: string | null;
        repositoryId: string | null;
        settingsJson: string;
        createdAt: string;
        updatedAt: string;
      }>();

    const projects = (rows.results ?? []).map((row) => ({
      id: row.id,
      name: row.name,
      description: row.description,
      repositoryId: row.repositoryId,
      settings: parseJson(row.settingsJson),
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    }));
    return json({ projects });
  }

  const isOwnerOrAdmin =
    context.workspaceRole === "owner" ||
    context.workspaceRole === "admin" ||
    testAuthenticationEnabled(env);
  const rows = isOwnerOrAdmin
    ? await env.CONCLAVE_DB.prepare(
        `SELECT p.id, p.workspace_id AS workspaceId, p.name, p.description, p.repository_id AS repositoryId,
                p.settings_json AS settingsJson, p.created_at AS createdAt, p.updated_at AS updatedAt
         FROM projects p WHERE p.workspace_id = ?1
           AND COALESCE(json_extract(p.settings_json, '$.archived'), 0) = 0
         ORDER BY p.updated_at DESC`,
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
           AND COALESCE(json_extract(p.settings_json, '$.archived'), 0) = 0
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

  if (context.authorizationModel === "v5") {
    // v5/v6 Projects are collaboration resources and deliberately have no
    // Workspace foreign key. Execution is attached later through an explicit
    // WorkspaceProjectGrant. Do not construct or validate the legacy Project
    // entity here: its workspaceId invariant belongs to the historical v4
    // model and would reject a valid zero-Workspace Project.
    await env.CONCLAVE_DB.batch([
      env.CONCLAVE_DB.prepare(
        `INSERT INTO projects (id, owner_user_id, name, description, repository_id, settings_json, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)`,
      ).bind(
        id,
        context.userId,
        name,
        description,
        repositoryId,
        JSON.stringify(settings),
        now,
      ),
      env.CONCLAVE_DB.prepare(
        `INSERT INTO project_memberships (id, project_id, user_id, role, created_at, updated_at)
         VALUES (?1, ?2, ?3, 'owner', ?4, ?4)
         ON CONFLICT(project_id, user_id) DO NOTHING`,
      ).bind(`pm-${crypto.randomUUID()}`, id, context.userId, now),
    ]);
    return json(
      {
        project: {
          id,
          name,
          description,
          repositoryId,
          settings,
          createdAt: now,
          updatedAt: now,
        },
      },
      { status: 201 },
    );
  } else {
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
}

async function handleGetProject(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(
    request,
    env,
    "projects:read",
    projectId,
    accessContext,
  );
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT p.id, p.name, p.description, p.repository_id AS repositoryId,
            p.settings_json AS settingsJson, p.created_at AS createdAt, p.updated_at AS updatedAt
     FROM projects p WHERE p.id = ?1`,
  )
    .bind(projectId)
    .first<{
      id: string;
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
      name: row.name,
      description: row.description,
      repositoryId: row.repositoryId,
      settings: parseJson(row.settingsJson),
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    },
  });
}

async function handleUpdateProject(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(
    request,
    env,
    "projects:write",
    projectId,
    accessContext,
  );
  const existing = await env.CONCLAVE_DB.prepare(
    `SELECT id, name, description,
            repository_id AS repositoryId, settings_json AS settingsJson,
            created_at AS createdAt, updated_at AS updatedAt
     FROM projects WHERE id = ?1`,
  )
    .bind(projectId)
    .first<{
      id: string;
      name: string;
      description: string | null;
      repositoryId: string | null;
      settingsJson: string;
      createdAt: string;
      updatedAt: string;
    }>();
  if (!existing) throw new HttpError(404, "Project not found");

  const body = (await request.json()) as Record<string, unknown>;
  const settings = {
    ...parseJson(existing.settingsJson),
    ...(typeof body.settings === "object" && body.settings !== null
      ? (body.settings as Record<string, unknown>)
      : {}),
  };
  if (body.archived === true) settings.archived = true;
  if (body.archived === false) settings.archived = false;
  const now = new Date().toISOString();
  const project = {
    id: existing.id,
    name:
      typeof body.name === "string" && body.name.trim().length > 0
        ? body.name.trim()
        : existing.name,
    description:
      body.description === null
        ? null
        : typeof body.description === "string"
          ? body.description
          : existing.description,
    repositoryId:
      body.repositoryId === null
        ? null
        : typeof body.repositoryId === "string"
          ? body.repositoryId
          : existing.repositoryId,
    settings,
    createdAt: existing.createdAt,
    updatedAt: now,
  };
  await env.CONCLAVE_DB.prepare(
    `UPDATE projects SET name = ?1, description = ?2, repository_id = ?3,
       settings_json = ?4, updated_at = ?5
     WHERE id = ?6`,
  )
    .bind(
      project.name,
      project.description,
      project.repositoryId,
      JSON.stringify(project.settings),
      now,
      projectId,
    )
    .run();
  return json({ project });
}

async function handleDeleteProject(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeRequest(
    request,
    env,
    "projects:manage",
    projectId,
    accessContext,
  );
  if (context.authorizationModel === "v5") {
    try {
      await authorizeProjectOwner(
        env.CONCLAVE_DB,
        context,
        projectId,
        "projects:manage",
      );
    } catch (error) {
      throw new HttpError(
        403,
        error instanceof Error ? error.message : "Forbidden",
      );
    }
    const result = await env.CONCLAVE_DB.prepare(
      "DELETE FROM projects WHERE id = ?1",
    )
      .bind(projectId)
      .run();
    if (!result.success || (result.meta?.changes ?? 0) === 0) {
      throw new HttpError(404, "Project not found");
    }
    return json({ projectId, deleted: true });
  }
  const result = await env.CONCLAVE_DB.prepare(
    "DELETE FROM projects WHERE id = ?1 AND workspace_id = ?2",
  )
    .bind(projectId, context.workspaceId)
    .run();
  if (!result.success || (result.meta?.changes ?? 0) === 0) {
    throw new HttpError(404, "Project not found");
  }
  return json({ projectId, deleted: true });
}

async function authorizeProjectOwnerOrThrow(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<SecurityContext> {
  const context = await authorizeRequest(
    request,
    env,
    "project:read",
    projectId,
    accessContext,
  );
  if (context.authorizationModel === "v5") {
    try {
      await authorizeProjectOwner(
        env.CONCLAVE_DB,
        context,
        projectId,
        "projects:manage",
      );
    } catch {
      throw new HttpError(
        403,
        "Only the Project owner can manage collaboration",
      );
    }
  }
  return context;
}

async function handleListProjectMembers(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(
    request,
    env,
    "project:read",
    projectId,
    accessContext,
  );
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT pm.user_id AS userId, u.display_name AS displayName, u.email, pm.role, pm.created_at AS createdAt
     FROM project_memberships pm JOIN users u ON u.id = pm.user_id
     WHERE pm.project_id = ?1 ORDER BY CASE pm.role WHEN 'owner' THEN 0 WHEN 'collaborator' THEN 1 ELSE 2 END, u.display_name`,
  )
    .bind(projectId)
    .all();
  return json({ members: rows.results ?? [] });
}

async function handleListProjectInvitations(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeProjectOwnerOrThrow(request, env, projectId, accessContext);
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, email, role, status, expires_at AS expiresAt, created_at AS createdAt
     FROM project_invitations WHERE project_id = ?1 AND status = 'pending' ORDER BY created_at DESC`,
  )
    .bind(projectId)
    .all();
  return json({ invitations: rows.results ?? [] });
}

async function handleListProjectAudit(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(
    request,
    env,
    "project:read",
    projectId,
    accessContext,
  );
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, action, target_type AS targetType, target_id AS targetId, created_at AS createdAt
     FROM project_audit_log WHERE project_id = ?1 ORDER BY created_at DESC LIMIT 100`,
  )
    .bind(projectId)
    .all();
  return json({ entries: rows.results ?? [] });
}

async function handleCreateProjectInvitation(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeProjectOwnerOrThrow(
    request,
    env,
    projectId,
    accessContext,
  );
  const body = (await request.json()) as Record<string, unknown>;
  const email = requiredString(body.email, "email").trim().toLowerCase();
  const role =
    body.role === "viewer" || body.role === "collaborator" ? body.role : null;
  if (!role || !email.includes("@"))
    throw new HttpError(400, "Valid email and Project role are required");
  const now = new Date();
  const id = `pinv-${crypto.randomUUID()}`;
  const token = `project_invite_${crypto.randomUUID()}_${crypto.randomUUID()}`;
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO project_invitations (id, project_id, email, role, token_hash, invited_by_user_id, status, expires_at, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'pending', ?7, ?8, ?8)`,
  )
    .bind(
      id,
      projectId,
      email,
      role,
      await hashToken(token),
      context.userId,
      new Date(now.getTime() + 7 * 86400000).toISOString(),
      now.toISOString(),
    )
    .run();
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO project_audit_log (id, project_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
     VALUES (?1, ?2, 'user', ?3, 'project.invitation.created', 'invitation', ?4, ?5, ?6)`,
  )
    .bind(
      `pa-${crypto.randomUUID()}`,
      projectId,
      context.userId,
      id,
      JSON.stringify({ email, role }),
      now.toISOString(),
    )
    .run();
  return json(
    { invitation: { id, projectId, email, role, status: "pending" }, token },
    { status: 201 },
  );
}

async function handleChangeProjectMemberRole(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  userId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeProjectOwnerOrThrow(
    request,
    env,
    projectId,
    accessContext,
  );
  const body = (await request.json()) as Record<string, unknown>;
  const role =
    body.role === "viewer" || body.role === "collaborator" ? body.role : null;
  if (!role)
    throw new HttpError(400, "Project role must be collaborator or viewer");
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE project_memberships SET role = ?1, updated_at = ?2 WHERE project_id = ?3 AND user_id = ?4 AND role <> 'owner'`,
  )
    .bind(role, new Date().toISOString(), projectId, userId)
    .run();
  if (!result.success || (result.meta?.changes ?? 0) === 0)
    throw new HttpError(404, "Project member not found");
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO project_audit_log (id, project_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) VALUES (?1, ?2, 'user', ?3, 'project.member.role_changed', 'user', ?4, ?5, ?6)`,
  )
    .bind(
      `pa-${crypto.randomUUID()}`,
      projectId,
      context.userId,
      userId,
      JSON.stringify({ role }),
      new Date().toISOString(),
    )
    .run();
  return json({ projectId, userId, role });
}

async function handleRemoveProjectMember(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  userId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeProjectOwnerOrThrow(
    request,
    env,
    projectId,
    accessContext,
  );
  const result = await env.CONCLAVE_DB.prepare(
    `DELETE FROM project_memberships WHERE project_id = ?1 AND user_id = ?2 AND role <> 'owner'`,
  )
    .bind(projectId, userId)
    .run();
  if (!result.success || (result.meta?.changes ?? 0) === 0)
    throw new HttpError(404, "Project member not found");
  // A contributed execution Workspace is owned by the departing user. Revoke
  // that user's Project Grants with the membership removal so the scheduler
  // cannot continue using infrastructure after collaboration ends.
  await env.CONCLAVE_DB.prepare(
    `UPDATE workspace_project_grants
        SET status = 'revoked', updated_at = ?1
      WHERE project_id = ?2 AND granted_by_user_id = ?3 AND status = 'active'`,
  )
    .bind(new Date().toISOString(), projectId, userId)
    .run();
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO project_audit_log (id, project_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) VALUES (?1, ?2, 'user', ?3, 'project.member.removed', 'user', ?4, '{}', ?5)`,
  )
    .bind(
      `pa-${crypto.randomUUID()}`,
      projectId,
      context.userId,
      userId,
      new Date().toISOString(),
    )
    .run();
  return json({ projectId, userId, removed: true });
}

async function handleExpireProjectInvitation(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  invitationId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await authorizeProjectOwnerOrThrow(
    request,
    env,
    projectId,
    accessContext,
  );
  const result = await env.CONCLAVE_DB.prepare(
    `UPDATE project_invitations SET status = 'expired', updated_at = ?1 WHERE id = ?2 AND project_id = ?3 AND status = 'pending'`,
  )
    .bind(new Date().toISOString(), invitationId, projectId)
    .run();
  if (!result.success || (result.meta?.changes ?? 0) === 0)
    throw new HttpError(404, "Pending invitation not found");
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO project_audit_log (id, project_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) VALUES (?1, ?2, 'user', ?3, 'project.invitation.expired', 'invitation', ?4, '{}', ?5)`,
  )
    .bind(
      `pa-${crypto.randomUUID()}`,
      projectId,
      context.userId,
      invitationId,
      new Date().toISOString(),
    )
    .run();
  return json({ id: invitationId, status: "expired" });
}

async function handleAcceptProjectInvitation(
  request: Request,
  env: SecurityEnv,
  invitationId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  const invitation = await env.CONCLAVE_DB.prepare(
    `SELECT id, project_id AS projectId, email, role, status, expires_at AS expiresAt
     FROM project_invitations WHERE id = ?1`,
  )
    .bind(invitationId)
    .first<{
      id: string;
      projectId: string;
      email: string;
      role: "collaborator" | "viewer";
      status: string;
      expiresAt: string;
    }>();
  if (!invitation || invitation.status !== "pending")
    throw new HttpError(404, "Project invitation not found");
  if (new Date(invitation.expiresAt).getTime() <= Date.now())
    throw new HttpError(410, "Project invitation expired");
  if (context.user.email.toLowerCase() !== invitation.email.toLowerCase())
    throw new HttpError(403, "Invitation email does not match signed-in user");
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `INSERT INTO project_memberships (id, project_id, user_id, role, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?5) ON CONFLICT(project_id, user_id) DO UPDATE SET role = excluded.role, updated_at = excluded.updated_at`,
    ).bind(
      `pm-${crypto.randomUUID()}`,
      invitation.projectId,
      context.userId,
      invitation.role,
      now,
    ),
    env.CONCLAVE_DB.prepare(
      `UPDATE project_invitations SET status = 'accepted', accepted_by_user_id = ?1, accepted_at = ?2, updated_at = ?2 WHERE id = ?3 AND status = 'pending'`,
    ).bind(context.userId, now, invitation.id),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO project_audit_log (id, project_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at) VALUES (?1, ?2, 'user', ?3, 'project.invitation.accepted', 'invitation', ?4, '{}', ?5)`,
    ).bind(
      `pa-${crypto.randomUUID()}`,
      invitation.projectId,
      context.userId,
      invitation.id,
      now,
    ),
  ]);
  return json({
    projectId: invitation.projectId,
    role: invitation.role,
    accepted: true,
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
  const metadata =
    typeof body.metadata === "object" && body.metadata !== null
      ? (body.metadata as Record<string, unknown>)
      : {};

  const projectRow = await env.CONCLAVE_DB.prepare(
    "SELECT repository_id AS repositoryId, settings_json AS settingsJson FROM projects WHERE id = ?1",
  )
    .bind(chatRow.projectId)
    .first<{ repositoryId: string | null; settingsJson: string }>();
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
    goalId: null,
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
      null,
      JSON.stringify(messageMetadata),
      now,
    ),
    env.CONCLAVE_DB.prepare(
      "UPDATE chats SET updated_at = ?1 WHERE id = ?2",
    ).bind(now, chatId),
  ]);

  try {
    await createEventPublisher(env).publish({
      type: "chat.message.created",
      workspaceId: chatRow.workspaceId,
      projectId: chatRow.projectId,
      chatId,
      idempotencyKey: `chat-message:${id}`,
      payload: {
        entityId: id,
        status: kind,
        summary: content.slice(0, 32768),
      },
    });
  } catch (error) {
    console.error("Failed to publish chat.message.created", error);
  }

  return json(
    {
      message,
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
// V6 Workstream Discuss / Work API
// =========================================================================

function workstreamMetadata(row: Record<string, unknown>): Record<string, unknown> {
  const accessPolicy = parseJson<Record<string, unknown>>(
    row.accessPolicyJson ?? row.access_policy_json,
    {},
  );
  return {
    id: String(row.id),
    projectId: String(row.projectId ?? row.project_id),
    name: String(row.name),
    status: String(row.status),
    lead: row.leadUserId ?? row.lead_user_id ?? null,
    accessPolicy,
    primaryWorkspace:
      accessPolicy.primaryWorkspaceId ?? accessPolicy.primary_workspace_id ?? null,
    currentCheckpoint: null,
    queueStatus: "Idle",
    createdAt: String(row.createdAt ?? row.created_at),
    updatedAt: String(row.updatedAt ?? row.updated_at),
  };
}

export function sortWorkstreams<T extends Record<string, unknown>>(
  workstreams: T[],
  workstreamOrder?: unknown,
): T[] {
  const hasCustomOrder =
    Array.isArray(workstreamOrder) && workstreamOrder.length > 0;
  const orderMap = new Map<string, number>();
  if (hasCustomOrder) {
    (workstreamOrder as unknown[]).forEach((id, index) => {
      if (typeof id === "string") orderMap.set(id, index);
    });
  }
  return [...workstreams].sort((a, b) => {
    const aId = String(a.id ?? "");
    const bId = String(b.id ?? "");
    if (hasCustomOrder) {
      const aIndex = orderMap.has(aId) ? orderMap.get(aId)! : 999999;
      const bIndex = orderMap.has(bId) ? orderMap.get(bId)! : 999999;
      if (aIndex !== bIndex) {
        return aIndex - bIndex;
      }
    }
    const aCreated = String(a.createdAt ?? a.created_at ?? "");
    const bCreated = String(b.createdAt ?? b.created_at ?? "");
    return aCreated.localeCompare(bCreated);
  });
}

export async function handleListProjectWorkstreams(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(request, env, "project:read", projectId, accessContext);
  const projectRow = await env.CONCLAVE_DB.prepare(
    `SELECT settings_json AS settingsJson FROM projects WHERE id = ?1`,
  )
    .bind(projectId)
    .first<{ settingsJson: string | null }>();
  const settings = parseJson(projectRow?.settingsJson);

  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, project_id AS projectId, name, status,
            access_policy_json AS accessPolicyJson,
            lead_user_id AS leadUserId,
            created_at AS createdAt, updated_at AS updatedAt
     FROM workstreams WHERE project_id = ?1 ORDER BY created_at ASC`,
  )
    .bind(projectId)
    .all<Record<string, unknown>>();

  const raw = (rows.results ?? []).map(workstreamMetadata);
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
  const id = `workstream-${crypto.randomUUID()}`;
  const now = new Date().toISOString();
  const accessPolicy =
    typeof body.accessPolicy === "object" && body.accessPolicy !== null
      ? body.accessPolicy
      : DEFAULT_WORKSTREAM_ACCESS_POLICY;
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workstreams
       (id, project_id, name, status, access_policy_json, lead_user_id, created_at, updated_at)
       VALUES (?1, ?2, ?3, 'active', ?4, ?5, ?6, ?6)`,
    ).bind(id, projectId, name, JSON.stringify(accessPolicy), context.userId, now),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO workstream_memberships
       (workstream_id, user_id, role, created_at)
       VALUES (?1, ?2, 'lead', ?3)`,
    ).bind(id, context.userId, now),
  ]);
  return json(
    {
      workstream: workstreamMetadata({
        id,
        projectId,
        name,
        status: "active",
        accessPolicyJson: JSON.stringify(accessPolicy),
        leadUserId: context.userId,
        createdAt: now,
        updatedAt: now,
      }),
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
    body.name === undefined ? workstream.name : requiredString(body.name, "name");
  const status =
    body.status === undefined ? workstream.status : String(body.status);
  if (!["active", "paused", "blocked", "completed", "archived"].includes(status)) {
    throw new HttpError(400, "Unsupported Workstream status");
  }
  const accessPolicy =
    body.accessPolicy === undefined
      ? workstream.accessPolicy
      : body.accessPolicy;
  if (typeof accessPolicy !== "object" || accessPolicy === null) {
    throw new HttpError(400, "accessPolicy must be an object");
  }
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `UPDATE workstreams
     SET name = ?1, status = ?2, access_policy_json = ?3, updated_at = ?4
     WHERE id = ?5`,
  )
    .bind(name, status, JSON.stringify(accessPolicy), now, workstreamId)
    .run();
  return json({
    workstream: workstreamMetadata({
      id: workstream.id,
      projectId: workstream.projectId,
      name,
      status,
      accessPolicyJson: JSON.stringify(accessPolicy),
      leadUserId: workstream.lead.userId,
      createdAt: workstream.createdAt,
      updatedAt: now,
    }),
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

function discussionReferences(value: unknown): readonly string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value))
    throw new HttpError(400, "references must be an array");
  return value.flatMap((reference) => {
    if (typeof reference === "string" && reference.trim())
      return [reference.trim()];
    if (reference && typeof reference === "object") {
      const id = (reference as Record<string, unknown>).id;
      if (typeof id === "string" && id.trim()) return [id.trim()];
    }
    throw new HttpError(400, "references must contain non-empty identifiers");
  });
}

type WorkstreamAccess = "view" | "discuss" | "execute" | "manage";

async function authorizeWorkstreamAccess(
  request: Request,
  env: SecurityEnv,
  workstreamId: string,
  access: WorkstreamAccess,
  accessContext?: ExecutionContext,
): Promise<{
  context: SecurityContext;
  workstream: Workstream;
  projectId: string;
}> {
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT id, project_id AS projectId, name, status,
            access_policy_json AS accessPolicyJson, lead_user_id AS leadUserId,
            created_at AS createdAt, updated_at AS updatedAt
     FROM workstreams WHERE id = ?1`,
  )
    .bind(workstreamId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Workstream not found");

  const permission: Permission =
    access === "view"
      ? "chats:read"
      : access === "discuss"
        ? "chats:create"
        : access === "execute"
          ? "run.start"
          : "projects:write";
  const context = await authorizeRequest(
    request,
    env,
    permission,
    String(row.projectId),
    accessContext,
  );
  const membership = await env.CONCLAVE_DB.prepare(
    `SELECT id, project_id AS projectId, user_id AS userId, role,
            created_at AS createdAt, updated_at AS updatedAt
     FROM project_memberships WHERE project_id = ?1 AND user_id = ?2`,
  )
    .bind(String(row.projectId), context.userId)
    .first<ProjectMembership>();
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
      userId: String(row.leadUserId),
      assignedAt: String(row.createdAt),
      assignedByUserId: String(row.leadUserId),
    },
    createdAt: String(row.createdAt),
    updatedAt: String(row.updatedAt),
  };
  const allowed =
    access === "view"
      ? canViewWorkstream(context.userId, membership, workstream)
      : access === "discuss"
        ? canDiscussWorkstream(context.userId, membership, workstream)
        : access === "execute"
          ? canExecuteWorkstream(context.userId, membership, workstream)
          : canManageWorkstream(context.userId, membership, workstream);
  if (!allowed)
    throw new HttpError(403, `Workstream ${access} access is required`);
  return { context, workstream, projectId: String(row.projectId) };
}

async function workstreamProjectId(
  env: SecurityEnv,
  workstreamId: string,
): Promise<string> {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT project_id AS projectId FROM workstreams WHERE id = ?1",
  )
    .bind(workstreamId)
    .first<{ projectId: string }>();
  if (!row) throw new HttpError(404, "Workstream not found");
  return row.projectId;
}

export async function handleListWorkstreamCheckouts(
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
    `SELECT id, workstream_id AS workstreamId, workspace_id AS workspaceId,
            repository_id AS repositoryId, revision, relative_path AS relativePath,
            status, created_at AS createdAt, updated_at AS updatedAt
     FROM workstream_checkouts WHERE workstream_id = ?1 ORDER BY created_at DESC`,
  )
    .bind(workstreamId)
    .all();
  return json({ checkouts: rows.results ?? [] });
}

export async function handleProvisionWorkstreamCheckout(
  request: Request,
  env: SecurityEnv,
  workstreamId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const projectId = await workstreamProjectId(env, workstreamId);
  const context = await authorizeRequest(
    request,
    env,
    "run.start",
    projectId,
    accessContext,
  );
  const membership = await env.CONCLAVE_DB.prepare(
    "SELECT role FROM project_memberships WHERE project_id = ?1 AND user_id = ?2",
  )
    .bind(projectId, context.userId)
    .first<{ role: string }>();
  if (!membership || membership.role === "viewer") {
    throw new HttpError(
      403,
      "Project membership with execute access is required",
    );
  }
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const requestedWorkspaceId =
    typeof body.workspaceId === "string" ? body.workspaceId : null;
  const workstream = await env.CONCLAVE_DB.prepare(
    `SELECT p.repository_id AS repositoryId,
            ep.primary_workspace_id AS primaryWorkspaceId
     FROM workstreams ws JOIN projects p ON p.id = ws.project_id
     LEFT JOIN workstream_execution_policies ep ON ep.workstream_id = ws.id
     WHERE ws.id = ?1`,
  )
    .bind(workstreamId)
    .first<{
      repositoryId: string | null;
      primaryWorkspaceId: string | null;
    }>();
  if (!workstream) throw new HttpError(404, "Workstream not found");
  if (!workstream.primaryWorkspaceId && !requestedWorkspaceId) {
    throw new HttpError(422, "A Primary Workspace must be selected first");
  }
  const workspaceId = requestedWorkspaceId ?? workstream.primaryWorkspaceId;
  if (!workspaceId) throw new HttpError(422, "A Primary Workspace is required");
  if (!workstream.repositoryId) {
    throw new HttpError(
      422,
      "Project repository is required before provisioning a checkout",
    );
  }
  const now = new Date().toISOString();
  const grant = await env.CONCLAVE_DB.prepare(
    `SELECT id FROM workspace_project_grants
     WHERE project_id = ?1 AND workspace_id = ?2 AND status = 'active'
       AND (expires_at IS NULL OR expires_at > ?3)`,
  )
    .bind(projectId, workspaceId, now)
    .first<{ id: string }>();
  if (!grant) throw new HttpError(409, "Workspace Project Grant is not active");
  const workspace = await env.CONCLAVE_DB.prepare(
    "SELECT status FROM execution_workspaces WHERE id = ?1",
  )
    .bind(workspaceId)
    .first<{ status: string }>();
  if (!workspace || workspace.status !== "online") {
    throw new HttpError(503, "Primary Workspace is offline");
  }
  const existing = await env.CONCLAVE_DB.prepare(
    `SELECT id, workstream_id AS workstreamId, workspace_id AS workspaceId,
            repository_id AS repositoryId, revision, relative_path AS relativePath,
            status, created_at AS createdAt, updated_at AS updatedAt
     FROM workstream_checkouts
     WHERE workstream_id = ?1 AND status IN ('provisioning', 'ready', 'stale')
     ORDER BY created_at DESC LIMIT 1`,
  )
    .bind(workstreamId)
    .first<Record<string, unknown>>();
  if (existing && existing.workspaceId !== workspaceId) {
    throw new HttpError(
      409,
      "Workstream already has a checkout on another Workspace",
    );
  }
  const checkoutId = existing
    ? String(existing.id)
    : `checkout-${crypto.randomUUID()}`;
  if (!existing) {
    await env.CONCLAVE_DB.prepare(
      `INSERT INTO workstream_checkouts
       (id, workstream_id, workspace_id, repository_id, revision, relative_path, status, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'provisioning', ?7, ?7)`,
    )
      .bind(
        checkoutId,
        workstreamId,
        workspaceId,
        workstream.repositoryId,
        typeof body.revision === "string" ? body.revision : "HEAD",
        `runtime_pending:${checkoutId}`,
        now,
      )
      .run();
  }
  if (!env.CONCLAVE_WORKSPACE_GATEWAY) {
    await env.CONCLAVE_DB.prepare(
      "UPDATE workstream_checkouts SET status = 'stale', updated_at = ?1 WHERE id = ?2",
    )
      .bind(now, checkoutId)
      .run();
    throw new HttpError(503, "Workspace Gateway is not configured");
  }
  {
    const stub = env.CONCLAVE_WORKSPACE_GATEWAY.getByName(workspaceId);
    const command = await stub.fetch(
      "https://workspace-gateway/provision-checkout",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          checkoutId,
          workstreamId,
          repositoryId: workstream.repositoryId,
        }),
      },
    );
    if (!command.ok) {
      await env.CONCLAVE_DB.prepare(
        "UPDATE workstream_checkouts SET status = 'stale', updated_at = ?1 WHERE id = ?2",
      )
        .bind(now, checkoutId)
        .run();
      throw new HttpError(
        command.status === 503 ? 503 : 409,
        "Workspace could not provision the checkout",
      );
    }
  }
  return json(
    {
      checkout: existing ?? {
        id: checkoutId,
        workstreamId,
        workspaceId,
        status: "provisioning",
      },
    },
    { status: existing ? 200 : 202 },
  );
}

async function handleListDiscussionMessages(
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

async function handleCreateDiscussionMessage(
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

async function handleEditDiscussionMessage(
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

async function handleCreateWorkRequest(
  request: Request,
  env: SecurityEnv,
  workstreamId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const { context, projectId } = await authorizeWorkstreamAccess(
    request,
    env,
    workstreamId,
    "execute",
    accessContext,
  );
  const membership = await env.CONCLAVE_DB.prepare(
    "SELECT role FROM project_memberships WHERE project_id = ?1 AND user_id = ?2",
  )
    .bind(projectId, context.userId)
    .first<{ role: "owner" | "collaborator" | "viewer" }>();
  if (!membership || membership.role === "viewer")
    throw new HttpError(
      403,
      "Project membership with execute access is required",
    );
  const body = (await request.json()) as Record<string, unknown>;
  const mode =
    body.mode === "stateful"
      ? "stateful"
      : body.mode === "stateless"
        ? "stateless"
        : null;
  if (!mode) throw new HttpError(400, "mode must be stateless or stateful");
  const workflowDefinitionId = requiredString(
    body.workflowDefinitionId,
    "workflowDefinitionId",
  );
  const workflowVersionId = requiredString(
    body.workflowVersionId,
    "workflowVersionId",
  );
  const snapshotValue = body.workflowVersionSnapshot ?? body.workflowVersion;
  if (!snapshotValue || typeof snapshotValue !== "object")
    throw new HttpError(400, "workflowVersionSnapshot is required");
  const workflowSnapshot = snapshotValue as WorkflowVersion;
  try {
    validateWorkflowVersion(workflowSnapshot);
  } catch (error) {
    throw new HttpError(
      400,
      error instanceof Error ? error.message : "Invalid workflow version",
    );
  }
  const persistedWorkflowVersion = await env.CONCLAVE_DB.prepare(
    `SELECT id, workflow_definition_id AS workflowDefinitionId, version
     FROM workflow_versions
     WHERE id = ?1 AND workflow_definition_id = ?2`,
  )
    .bind(workflowVersionId, workflowDefinitionId)
    .first<{ id: string; workflowDefinitionId: string; version: number }>();
  if (!persistedWorkflowVersion)
    throw new HttpError(404, "Workflow version not found");
  if (persistedWorkflowVersion.version !== workflowSnapshot.version)
    throw new HttpError(
      409,
      "Workflow version snapshot does not match the stored version",
    );
  const policyRow = await env.CONCLAVE_DB.prepare(
    "SELECT mode, primary_workspace_id AS primaryWorkspaceId, require_checkout AS requireCheckout, max_concurrent_work_requests AS maxConcurrentWorkRequests FROM workstream_execution_policies WHERE workstream_id = ?1",
  )
    .bind(workstreamId)
    .first<WorkstreamExecutionPolicy>();
  const policy: WorkstreamExecutionPolicy = policyRow ?? {
    mode,
    primaryWorkspaceId:
      typeof body.primaryWorkspaceId === "string"
        ? body.primaryWorkspaceId
        : null,
    requireCheckout: mode === "stateful",
    maxConcurrentWorkRequests: 1,
  };
  const now = new Date().toISOString();
  const workRequest: WorkRequest = {
    id: `work-request-${crypto.randomUUID()}`,
    workstreamId,
    requestedByUserId: context.userId,
    mode,
    workflowDefinitionId,
    workflowVersionId,
    workflowVersionSnapshot: workflowSnapshot,
    status: "queued",
    primaryWorkspaceId:
      typeof body.primaryWorkspaceId === "string"
        ? body.primaryWorkspaceId
        : null,
    checkoutId: typeof body.checkoutId === "string" ? body.checkoutId : null,
    input:
      body.input && typeof body.input === "object"
        ? (body.input as Record<string, unknown>)
        : {},
    createdAt: now,
    updatedAt: now,
  };
  try {
    validateWorkRequest(workRequest, policy);
  } catch (error) {
    throw new HttpError(
      400,
      error instanceof Error ? error.message : "Invalid Work Request",
    );
  }
  const runId = `run-${crypto.randomUUID()}`;
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      `INSERT INTO work_requests
       (id, workstream_id, requested_by_user_id, mode, workflow_definition_id, workflow_version_id, workflow_snapshot_json, status, primary_workspace_id, checkout_id, input_json, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'queued', ?8, ?9, ?10, ?11, ?11)`,
    ).bind(
      workRequest.id,
      workstreamId,
      context.userId,
      mode,
      workflowDefinitionId,
      workflowVersionId,
      JSON.stringify(workflowSnapshot),
      workRequest.primaryWorkspaceId,
      workRequest.checkoutId,
      JSON.stringify(workRequest.input),
      now,
    ),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO runs
       (id, project_id, workstream_id, work_request_id, workflow_version_id, checkout_id, status, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'created', ?7, ?7)`,
    ).bind(
      runId,
      projectId,
      workstreamId,
      workRequest.id,
      workflowVersionId,
      workRequest.checkoutId,
      now,
    ),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO project_audit_log
       (id, project_id, actor_type, actor_id, action, target_type, target_id, details_json, created_at)
       VALUES (?1, ?2, 'user', ?3, 'workstream.work_requested', 'work_request', ?4, ?5, ?6)`,
    ).bind(
      `pa-${crypto.randomUUID()}`,
      projectId,
      context.userId,
      workRequest.id,
      JSON.stringify({ workstreamId, runId, workflowVersionId }),
      now,
    ),
  ]);
  if (mode === "stateful" && env.CONCLAVE_WORKSTREAM_COORDINATOR) {
    const coordinator = env.CONCLAVE_WORKSTREAM_COORDINATOR.getByName(workstreamId);
    const response = await coordinator.fetch(
      new Request("https://workstream-coordinator/enqueue", {
        method: "POST",
        headers: { "content-type": "application/json", "x-workstream-id": workstreamId },
        body: JSON.stringify({ workRequestId: workRequest.id }),
      }),
    );
    if (!response.ok) {
      throw new HttpError(503, "Workstream execution coordinator unavailable");
    }
  }
  return json(
    {
      workRequest,
      run: { id: runId, projectId, workstreamId, status: "created" },
    },
    { status: 202 },
  );
}

async function handleCancelWorkRequest(
  request: Request,
  env: SecurityEnv,
  workRequestId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT workstream_id AS workstreamId, mode, status FROM work_requests WHERE id = ?1",
  ).bind(workRequestId).first<{ workstreamId: string; mode: string; status: string }>();
  if (!row) throw new HttpError(404, "Work Request not found");
  if (row.mode !== "stateful") throw new HttpError(400, "Only stateful Work Requests can be cancelled here");
  await authorizeWorkstreamAccess(request, env, row.workstreamId, "execute", accessContext);
  if (!env.CONCLAVE_WORKSTREAM_COORDINATOR) throw new HttpError(503, "Workstream execution coordinator unavailable");
  const coordinator = env.CONCLAVE_WORKSTREAM_COORDINATOR.getByName(row.workstreamId);
  return coordinator.fetch(
    new Request("https://workstream-coordinator/cancel", {
      method: "POST",
      headers: { "content-type": "application/json", "x-workstream-id": row.workstreamId },
      body: JSON.stringify({ workRequestId }),
    }),
  );
}

// =========================================================================
// Agent Enrollment & Fleet Handlers
// =========================================================================

async function handleCreateHostEnrollment(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "host.manage");
  await requireWorkspaceContext(context, env, workspaceId);

  const body = parseJson<{ expiresHours?: number }>(await request.text(), {});
  const enrollmentId = `enr-${crypto.randomUUID().slice(0, 12)}`;
  const token = `conclave_enroll_${crypto.randomUUID().replace(/-/g, "")}`;
  const tokenHash = await hashToken(token);
  const now = new Date();
  const expiresHours = body.expiresHours ?? 24;
  if (
    !Number.isInteger(expiresHours) ||
    expiresHours < 1 ||
    expiresHours > 168
  ) {
    return json(
      { error: "expiresHours must be an integer between 1 and 168" },
      { status: 400 },
    );
  }
  const expiresAt = new Date(
    now.getTime() + expiresHours * 3600 * 1000,
  ).toISOString();
  const createdAt = now.toISOString();

  await env.CONCLAVE_DB.prepare(
    `INSERT INTO workspace_enrollments (id, workspace_id, token_hash, created_by_user_id, expires_at, created_at)
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
    "workspace.enrollment.created",
    "workspace_enrollment",
    enrollmentId,
    { expiresAt, oneTime: true },
    workspaceId,
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

async function handleListHostEnrollments(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "host.view");
  await requireWorkspaceContext(context, env, workspaceId);

  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT id, workspace_id as workspaceId, created_by_user_id as createdByUserId, expires_at as expiresAt, used_at as usedAt, revoked_at as revokedAt, created_at as createdAt
     FROM workspace_enrollments WHERE workspace_id = ?1 ORDER BY created_at DESC`,
  )
    .bind(workspaceId)
    .all();

  return json({ enrollments: rows.results ?? [] });
}

async function handleRevokeHostEnrollment(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  enrollmentId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "host.manage");
  await requireWorkspaceContext(context, env, workspaceId);
  await requireRecentStepUp(env, context, SENSITIVE_OPERATIONS.hostRevoke);

  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `UPDATE workspace_enrollments SET revoked_at = ?1 WHERE id = ?2 AND workspace_id = ?3`,
  )
    .bind(now, enrollmentId, workspaceId)
    .run();

  await recordAudit(
    env,
    context,
    "workspace.enrollment.revoked",
    "workspace_enrollment",
    enrollmentId,
  );

  return json({ ok: true, revokedAt: now });
}

async function handleEnrollHost(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  const body = parseJson<{
    token?: string;
    name?: string;
    hostname?: string;
    hostId?: string;
  }>(await request.text(), {});

  if (!body.token) {
    return json({ error: "Enrollment token is required" }, { status: 400 });
  }

  const tokenHash = await hashToken(body.token);
  const now = new Date().toISOString();

  const enrollment = await env.CONCLAVE_DB.prepare(
    `SELECT * FROM host_enrollments
       WHERE token_hash = ?1
         AND revoked_at IS NULL
         AND used_at IS NULL
         AND expires_at > ?2`,
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

  const hostId = body.hostId || `host-${crypto.randomUUID().slice(0, 8)}`;
  const authToken = `conclave_host_tok_${crypto.randomUUID().replace(/-/g, "")}`;
  const authTokenHash = await hashToken(authToken);

  await env.CONCLAVE_DB.prepare(
    `INSERT INTO hosts (id, name, hostname, status, version, capabilities_json, auth_token_hash, enrolled_at, created_at, updated_at)
     VALUES (?1, ?2, ?3, 'enrolled', '0.2.0', '{}', ?4, ?5, ?5, ?5)
     ON CONFLICT(id) DO UPDATE SET
       auth_token_hash = excluded.auth_token_hash,
       status = 'enrolled',
       revoked_at = NULL,
       updated_at = excluded.updated_at`,
  )
    .bind(
      hostId,
      body.name || `Host ${hostId}`,
      body.hostname || "localhost",
      authTokenHash,
      now,
    )
    .run();

  await env.CONCLAVE_DB.prepare(
    `INSERT INTO host_workspace_bindings (id, host_id, workspace_id, status, granted_by_user_id, created_at, updated_at)
     VALUES (?1, ?2, ?3, 'active', ?4, ?5, ?5)
     ON CONFLICT(host_id, workspace_id) DO UPDATE SET status = 'active', updated_at = excluded.updated_at`,
  )
    .bind(
      `binding-${hostId}-${enrollment.workspace_id}`,
      hostId,
      enrollment.workspace_id,
      enrollment.created_by_user_id,
      now,
    )
    .run();

  await env.CONCLAVE_DB.prepare(
    `UPDATE host_enrollments SET used_at = ?1 WHERE id = ?2`,
  )
    .bind(now, enrollment.id)
    .run();

  return json(
    {
      hostId,
      workspaceId: enrollment.workspace_id,
      authToken,
    },
    { status: 201 },
  );
}

async function handleBindHostWorkspace(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  hostId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "host.bind_workspace");
  await requireWorkspaceContext(context, env, workspaceId);

  // Binding a Host to another Workspace is an administrative action in the
  // target Workspace and also requires management authority through an
  // existing active binding. This prevents the original installer from
  // becoming a permanent ownership shortcut.
  await authorizeHostWorkspaceAction(
    env.CONCLAVE_DB,
    context.userId,
    hostId,
    "host.manage",
  );

  const host = await env.CONCLAVE_DB.prepare(
    `SELECT id FROM hosts WHERE id = ?1 AND revoked_at IS NULL`,
  )
    .bind(hostId)
    .first<{ id: string }>();
  if (!host) return json({ error: "Host not found" }, { status: 404 });

  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO host_workspace_bindings
       (id, host_id, workspace_id, status, granted_by_user_id, created_at, updated_at)
     VALUES (?1, ?2, ?3, 'active', ?4, ?5, ?5)
     ON CONFLICT(host_id, workspace_id) DO UPDATE SET
       status = 'active', granted_by_user_id = excluded.granted_by_user_id,
       updated_at = excluded.updated_at`,
  )
    .bind(
      `binding-${hostId}-${workspaceId}`,
      hostId,
      workspaceId,
      context.userId,
      now,
    )
    .run();

  await recordAudit(env, context, "host.workspace.bound", "host", hostId, {
    workspaceId,
  });
  return json({ ok: true, hostId, workspaceId, boundAt: now }, { status: 201 });
}

async function handleListHosts(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "host.view");
  await requireWorkspaceContext(context, env, workspaceId);

  if (context.authorizationModel === "v5") {
    const workspace = await env.CONCLAVE_DB.prepare(
      `SELECT id, name, status, created_at AS createdAt, updated_at AS updatedAt
       FROM execution_workspaces
       WHERE id = ?1 AND owner_user_id = ?2`,
    )
      .bind(workspaceId, context.userId)
      .first<{
        id: string;
        name: string;
        status: string;
        createdAt: string;
        updatedAt: string;
      }>();
    if (!workspace) throw new HttpError(404, "Workspace not found");
    return json({
      hosts: [
        {
          id: workspace.id,
          workspaceId: workspace.id,
          name: workspace.name,
          hostname: "—",
          status: workspace.status,
          version: "—",
          capabilitiesJson: "[]",
          enrolledAt: workspace.createdAt,
          lastHeartbeatAt: null,
          revokedAt: workspace.status === "revoked" ? workspace.updatedAt : null,
          createdAt: workspace.createdAt,
          updatedAt: workspace.updatedAt,
          desiredWorkers: [],
          installedWorkers: [],
        },
      ],
    });
  }

  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT h.id, b.workspace_id as workspaceId, h.name, h.hostname, h.status, h.version, h.capabilities_json as capabilitiesJson, h.enrolled_at as enrolledAt, h.last_heartbeat_at as lastHeartbeatAt, h.revoked_at as revokedAt, h.created_at as createdAt, h.updated_at as updatedAt,
       COALESCE((SELECT json_group_array(json_object(
         'workerId', dw.worker_id,
         'version', dw.required_version
       )) FROM host_desired_workers dw WHERE dw.host_id = h.id), '[]') AS desiredWorkersJson,
       COALESCE((SELECT json_group_array(json_object(
         'workerId', i.worker_id,
         'version', wv.version,
         'status', i.status
       )) FROM host_worker_installations i
       JOIN worker_versions wv ON wv.id = i.worker_version_id
       WHERE i.host_id = h.id AND i.status <> 'removed'), '[]') AS installedWorkersJson
     FROM hosts h JOIN host_workspace_bindings b ON b.host_id = h.id
     WHERE b.workspace_id = ?1 AND b.status = 'active' ORDER BY h.created_at DESC`,
  )
    .bind(workspaceId)
    .all<Record<string, unknown>>();

  return json({
    hosts: (rows.results ?? []).map((row) => {
      let desiredWorkers: unknown[] = [];
      let installedWorkers: unknown[] = [];
      try {
        const parsed = JSON.parse(String(row.desiredWorkersJson ?? "[]"));
        if (Array.isArray(parsed)) desiredWorkers = parsed;
      } catch {
        // Keep the read model usable if an older row contains malformed JSON.
      }
      try {
        const parsed = JSON.parse(String(row.installedWorkersJson ?? "[]"));
        if (Array.isArray(parsed)) installedWorkers = parsed;
      } catch {
        // Keep the read model usable if an older row contains malformed JSON.
      }
      return {
        ...row,
        desiredWorkers,
        installedWorkers,
        desiredWorkersJson: undefined,
        installedWorkersJson: undefined,
      };
    }),
  });
}

async function handleGetHost(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  hostId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "host.view");
  await requireWorkspaceContext(context, env, workspaceId);

  const host = await env.CONCLAVE_DB.prepare(
    `SELECT h.id, b.workspace_id as workspaceId, h.name, h.hostname, h.status, h.version, h.capabilities_json as capabilitiesJson, h.enrolled_at as enrolledAt, h.last_heartbeat_at as lastHeartbeatAt, h.revoked_at as revokedAt, h.created_at as createdAt, h.updated_at as updatedAt
     FROM hosts h JOIN host_workspace_bindings b ON b.host_id = h.id
     WHERE b.workspace_id = ?1 AND b.status = 'active' AND h.id = ?2`,
  )
    .bind(workspaceId, hostId)
    .first();

  if (!host) return json({ error: "Host not found" }, { status: 404 });

  const sessions = await env.CONCLAVE_DB.prepare(
    `SELECT id, client_version as clientVersion, protocol_version as protocolVersion, connected_at as connectedAt, last_heartbeat_at as lastHeartbeatAt, disconnected_at as disconnectedAt
     FROM host_sessions WHERE host_id = ?1 ORDER BY connected_at DESC LIMIT 10`,
  )
    .bind(hostId)
    .all();

  const bindings = await env.CONCLAVE_DB.prepare(
    `SELECT workspace_id as workspaceId, status,
            granted_by_user_id as grantedByUserId, created_at as createdAt,
            updated_at as updatedAt
     FROM host_workspace_bindings WHERE host_id = ?1 ORDER BY created_at`,
  )
    .bind(hostId)
    .all();
  const members = await env.CONCLAVE_DB.prepare(
    `SELECT DISTINCT m.workspace_id as workspaceId, m.user_id as userId,
            u.display_name as displayName, u.email, m.role
     FROM host_workspace_bindings b
     JOIN workspace_memberships m
       ON m.workspace_id = b.workspace_id AND m.status = 'active'
     JOIN users u ON u.id = m.user_id
     WHERE b.host_id = ?1 AND b.status = 'active'
     ORDER BY m.workspace_id, m.role, u.display_name`,
  )
    .bind(hostId)
    .all();
  const installedWorkers = await env.CONCLAVE_DB.prepare(
    `SELECT i.worker_id as workerId, w.display_name as displayName,
            i.worker_version_id as workerVersionId, v.version, i.status,
            i.error, i.installed_at as installedAt, i.updated_at as updatedAt
     FROM host_worker_installations i
     JOIN workers w ON w.id = i.worker_id
     JOIN worker_versions v ON v.id = i.worker_version_id
     WHERE i.host_id = ?1 AND i.status <> 'removed'
     ORDER BY w.display_name, v.version`,
  )
    .bind(hostId)
    .all();
  const load = await env.CONCLAVE_DB.prepare(
    `SELECT COUNT(*) as activeAssignments
     FROM worker_assignments
     WHERE host_id = ?1 AND status IN ('queued', 'assigned', 'running', 'cancelling')`,
  )
    .bind(hostId)
    .first<{ activeAssignments: number }>();
  const accountRows = await env.CONCLAVE_DB.prepare(
    `SELECT id, display_name as displayName, owner_type as ownerType,
            owner_id as ownerId, worker_id as workerId, host_id as hostId,
            auth_type as authType, status, sharing_policy as sharingPolicy,
            provider_metadata_json as providerMetadataJson,
            concurrency_limit as concurrencyLimit
     FROM credential_profiles
     WHERE workspace_id = ?1 AND (host_id IS NULL OR host_id = ?2)
       AND status <> 'revoked'
     ORDER BY display_name`,
  )
    .bind(workspaceId, hostId)
    .all<Record<string, unknown>>();
  const accounts = [];
  for (const account of accountRows.results ?? []) {
    try {
      await authorizeCredentialProfileUse(
        env.CONCLAVE_DB,
        context,
        String(account.id),
      );
      accounts.push({
        ...account,
        providerMetadata: parseJson(account.providerMetadataJson, {}),
        providerMetadataJson: undefined,
      });
    } catch {
      // Account visibility is requester-specific and never reveals secrets.
    }
  }

  return json({
    host,
    sessions: sessions.results ?? [],
    bindings: bindings.results ?? [],
    members: members.results ?? [],
    load: load ?? { activeAssignments: 0 },
    installedWorkers: installedWorkers.results ?? [],
    accounts,
  });
}

async function handleRevokeHost(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  hostId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "host.revoke");
  await requireWorkspaceContext(context, env, workspaceId);
  await requireRecentStepUp(env, context, SENSITIVE_OPERATIONS.hostRevoke);

  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `UPDATE hosts SET status = 'revoked', revoked_at = ?1, updated_at = ?1
     WHERE id = ?3 AND EXISTS (SELECT 1 FROM host_workspace_bindings b WHERE b.host_id = hosts.id AND b.workspace_id = ?2 AND b.status = 'active')`,
  )
    .bind(now, workspaceId, hostId)
    .run();

  await recordAudit(env, context, "host.revoked", "host", hostId, {
    revokedAt: now,
  });

  return json({ ok: true, revokedAt: now });
}

async function handleUpdateHost(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  hostId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "host.manage");
  await requireWorkspaceContext(context, env, workspaceId);
  const body = (await request.json()) as Record<string, unknown>;
  const name = typeof body.name === "string" ? body.name.trim() : undefined;
  const channel = typeof body.channel === "string" ? body.channel : undefined;
  if (name !== undefined && name.length === 0) {
    throw new HttpError(400, "Host name cannot be empty");
  }
  if (
    channel !== undefined &&
    !["stable", "beta", "development"].includes(channel)
  ) {
    throw new HttpError(400, "Unsupported release channel");
  }
  const host = await env.CONCLAVE_DB.prepare(
    `SELECT h.id, h.name, h.capabilities_json AS capabilitiesJson
     FROM hosts h JOIN host_workspace_bindings b ON b.host_id = h.id
     WHERE h.id = ?1 AND b.workspace_id = ?2 AND b.status = 'active' AND h.revoked_at IS NULL`,
  )
    .bind(hostId, workspaceId)
    .first<{ id: string; name: string; capabilitiesJson: string }>();
  if (!host) throw new HttpError(404, "Host not found");
  const capabilities = parseJson<Record<string, unknown>>(
    host.capabilitiesJson,
    {},
  );
  if (channel !== undefined) capabilities.updateChannel = channel;
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `UPDATE hosts SET name = ?1, capabilities_json = ?2, updated_at = ?3
     WHERE id = ?4`,
  )
    .bind(name ?? host.name, JSON.stringify(capabilities), now, hostId)
    .run();
  await recordAudit(env, context, "host.updated", "host", hostId, {
    name: name ?? host.name,
    channel: channel ?? null,
  });
  return json({
    ok: true,
    hostId,
    name: name ?? host.name,
    channel: channel ?? null,
  });
}

async function handleAnnounceHostUpdate(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  hostId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "host.manage");
  await requireWorkspaceContext(context, env, workspaceId);

  const body = parseJson<{
    channel?: string;
    version?: string;
  }>(await request.text(), {});
  const channel = body.channel || "stable";
  if (!["stable", "beta", "development"].includes(channel)) {
    return json({ error: "Unsupported release channel" }, { status: 400 });
  }

  const host = await env.CONCLAVE_DB.prepare(
    `SELECT h.id, h.version, h.capabilities_json as capabilitiesJson
     FROM hosts h JOIN host_workspace_bindings b ON b.host_id = h.id
     WHERE b.workspace_id = ?1 AND b.status = 'active' AND h.id = ?2 AND h.revoked_at IS NULL`,
  )
    .bind(workspaceId, hostId)
    .first<{
      id: string;
      version: string;
      capabilitiesJson: string;
    }>();
  if (!host) return json({ error: "Host not found" }, { status: 404 });

  const capabilities = parseJson<Record<string, unknown>>(
    host.capabilitiesJson,
    {},
  );
  const operatingSystem =
    typeof capabilities.os === "string" ? capabilities.os : null;
  const architecture =
    typeof capabilities.arch === "string" ? capabilities.arch : null;
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT version, channel, min_supported_host_version as minSupportedHostVersion,
            supported_os_json as supportedOsJson, supported_arch_json as supportedArchJson,
            package_digest as packageDigest, package_r2_key as packageR2Key,
            signature, release_notes as releaseNotes
     FROM host_releases
     WHERE channel = ?1 AND is_revoked = 0`,
  )
    .bind(channel)
    .all<{
      version: string;
      channel: string;
      minSupportedHostVersion: string | null;
      supportedOsJson: string;
      supportedArchJson: string;
      packageDigest: string;
      packageR2Key: string;
      signature: string;
      releaseNotes: string | null;
    }>();

  const compatible = (release: (typeof rows.results)[number]) => {
    const supportedOS = parseJson<string[]>(release.supportedOsJson, []);
    const supportedArch = parseJson<string[]>(release.supportedArchJson, []);
    return (
      (!operatingSystem ||
        supportedOS.length === 0 ||
        supportedOS.includes(operatingSystem)) &&
      (!architecture ||
        supportedArch.length === 0 ||
        supportedArch.includes(architecture)) &&
      compareSemver(release.version, host.version) > 0
    );
  };
  const candidates = (rows.results ?? []).filter(compatible);
  const release = body.version
    ? candidates.find((candidate) => candidate.version === body.version)
    : [...candidates].sort((a, b) => compareSemver(b.version, a.version))[0];
  if (!release) {
    return json(
      {
        error: body.version
          ? "Requested update is unavailable"
          : "No update is available",
      },
      { status: 404 },
    );
  }

  const envelope = {
    protocol: AGENT_PROTOCOL_NAME,
    protocolVersion: AGENT_PROTOCOL_VERSION,
    messageId: `msg-${crypto.randomUUID()}`,
    timestamp: new Date().toISOString(),
    type: "agent.update.available" as const,
    payload: {
      version: release.version,
      channel: release.channel as "stable" | "beta" | "development",
      packageR2Key: release.packageR2Key,
      packageDigest: release.packageDigest,
      signature: release.signature,
      ...(release.releaseNotes ? { releaseNotes: release.releaseNotes } : {}),
      ...(release.minSupportedHostVersion
        ? { minSupportedHostVersion: release.minSupportedHostVersion }
        : {}),
    },
  };
  const gateway = env.CONCLAVE_HOST_GATEWAY.getByName(hostId);
  const delivered = await gateway.fetch(
    new Request("https://gateway.internal/post-message", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(envelope),
    }),
  );
  if (!delivered.ok) {
    return json(
      {
        error:
          delivered.status === 503
            ? "Host is currently offline"
            : "Could not deliver update announcement",
      },
      { status: delivered.status === 503 ? 503 : 502 },
    );
  }

  await recordAudit(env, context, "host.update.announced", "host", hostId, {
    version: release.version,
    channel: release.channel,
  });
  return json({
    delivered: true,
    hostId,
    version: release.version,
    channel: release.channel,
  });
}

async function handleSetHostDesiredState(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  hostId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "worker.manage_on_host");
  await requireWorkspaceContext(context, env, workspaceId);

  const binding = await env.CONCLAVE_DB.prepare(
    `SELECT h.id FROM hosts h
     JOIN host_workspace_bindings b ON b.host_id = h.id
     WHERE h.id = ?1 AND b.workspace_id = ?2 AND b.status = 'active'
       AND h.revoked_at IS NULL`,
  )
    .bind(hostId, workspaceId)
    .first<{ id: string }>();
  if (!binding) throw new HttpError(404, "Host not found");

  const body = (await request.json()) as Record<string, unknown>;
  const rawWorkers = Array.isArray(body.requiredWorkers)
    ? body.requiredWorkers
    : [];
  const requiredWorkers = rawWorkers.map((item, index) => {
    if (!item || typeof item !== "object") {
      throw new HttpError(400, `requiredWorkers[${index}] must be an object`);
    }
    const worker = item as Record<string, unknown>;
    if (
      typeof worker.workerId !== "string" ||
      typeof worker.version !== "string" ||
      worker.workerId.length === 0 ||
      worker.version.length === 0
    ) {
      throw new HttpError(
        400,
        `requiredWorkers[${index}] requires workerId and version`,
      );
    }
    return { workerId: worker.workerId, version: worker.version };
  });
  const uniqueWorkers = new Map(
    requiredWorkers.map((worker) => [worker.workerId, worker]),
  );

  const releaseChannel =
    body.releaseChannel === undefined ? "stable" : body.releaseChannel;
  if (
    releaseChannel !== "stable" &&
    releaseChannel !== "beta" &&
    releaseChannel !== "development"
  ) {
    throw new HttpError(400, "Unsupported Host release channel");
  }
  const listOfStrings = (value: unknown, field: string): string[] => {
    if (value === undefined) return [];
    if (
      !Array.isArray(value) ||
      value.some((item) => typeof item !== "string")
    ) {
      throw new HttpError(400, `${field} must be an array of strings`);
    }
    return value as string[];
  };
  const credentialSetupRequests = listOfStrings(
    body.credentialSetupRequests,
    "credentialSetupRequests",
  );
  const localPermissionRequests = listOfStrings(
    body.localPermissionRequests,
    "localPermissionRequests",
  );

  for (const worker of uniqueWorkers.values()) {
    const version = await env.CONCLAVE_DB.prepare(
      `SELECT wv.id FROM worker_versions wv
       JOIN workers w ON w.id = wv.worker_id
       WHERE wv.worker_id = ?1 AND wv.version = ?2
         AND w.status = 'active' AND wv.is_revoked = 0`,
    )
      .bind(worker.workerId, worker.version)
      .first<{ id: string }>();
    if (!version) {
      throw new HttpError(
        409,
        `Worker version ${worker.workerId}@${worker.version} is unavailable`,
      );
    }
  }

  const existing = await env.CONCLAVE_DB.prepare(
    "SELECT revision FROM host_desired_states WHERE host_id = ?1",
  )
    .bind(hostId)
    .first<{ revision: number }>();
  const revision = (existing?.revision ?? 0) + 1;
  const now = new Date().toISOString();
  const statements: D1PreparedStatement[] = [
    env.CONCLAVE_DB.prepare(
      `INSERT INTO host_desired_states
       (host_id, release_channel, credential_setup_requests_json,
        local_permission_requests_json, revision, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6)
       ON CONFLICT(host_id) DO UPDATE SET
         release_channel = excluded.release_channel,
         credential_setup_requests_json = excluded.credential_setup_requests_json,
         local_permission_requests_json = excluded.local_permission_requests_json,
         revision = excluded.revision,
         updated_at = excluded.updated_at`,
    ).bind(
      hostId,
      releaseChannel,
      JSON.stringify(credentialSetupRequests),
      JSON.stringify(localPermissionRequests),
      revision,
      now,
    ),
    env.CONCLAVE_DB.prepare(
      "DELETE FROM host_desired_workers WHERE host_id = ?1",
    ).bind(hostId),
  ];
  for (const worker of uniqueWorkers.values()) {
    statements.push(
      env.CONCLAVE_DB.prepare(
        `INSERT INTO host_desired_workers
         (host_id, worker_id, required_version, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?4)`,
      ).bind(hostId, worker.workerId, worker.version, now),
    );
  }
  await env.CONCLAVE_DB.batch(statements);
  await recordAudit(
    env,
    context,
    "host.desired_state.updated",
    "host",
    hostId,
    {
      revision,
      requiredWorkers: [...uniqueWorkers.values()],
      releaseChannel,
    },
  );

  return json({
    hostId,
    workspaceId,
    revision,
    releaseChannel,
    requiredWorkers: [...uniqueWorkers.values()],
    credentialSetupRequests,
    localPermissionRequests,
    updatedAt: now,
  });
}

export async function handleListWorkerCatalog(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "host.view");
  await requireWorkspaceContext(context, env, workspaceId);
  if (context.authorizationModel === "v5") {
    const rows = await env.CONCLAVE_DB.prepare(
      `SELECT id, display_name AS displayName, description, publisher, status
       FROM workers WHERE status <> 'revoked' ORDER BY display_name, id`,
    ).all<Record<string, unknown>>();
    return json({
      workers: (rows.results ?? []).map((row) => ({
        ...row,
        latestVersion: null,
        capabilities: [],
        credentialRequirements: [],
      })),
    });
  }
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT w.id, w.display_name, w.description, w.publisher, w.status,
            wv.version, wv.capabilities_json, wv.credential_requirements_json
       FROM workers w
       LEFT JOIN worker_versions wv
         ON wv.worker_id = w.id AND wv.is_revoked = 0
        AND wv.created_at = (SELECT MAX(latest.created_at) FROM worker_versions latest
                             WHERE latest.worker_id = w.id AND latest.is_revoked = 0)
      WHERE w.status != 'revoked'
      ORDER BY w.display_name, w.id`,
  ).all<Record<string, unknown>>();
  return json({
    workers: (rows.results ?? []).map((row) => ({
      id: String(row.id),
      displayName: String(row.display_name),
      description: String(row.description ?? ""),
      publisher: String(row.publisher),
      status: String(row.status),
      latestVersion: row.version == null ? null : String(row.version),
      capabilities: parseJson(row.capabilities_json, []),
      credentialRequirements: parseJson(row.credential_requirements_json, []),
    })),
  });
}

export async function handleGetWorkerCatalog(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  workerId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "host.view");
  await requireWorkspaceContext(context, env, workspaceId);
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT w.id, w.display_name, w.description, w.publisher, w.status,
            wv.version, wv.capabilities_json, wv.credential_requirements_json
       FROM workers w
       LEFT JOIN worker_versions wv
         ON wv.worker_id = w.id AND wv.is_revoked = 0
        AND wv.created_at = (SELECT MAX(latest.created_at) FROM worker_versions latest
                             WHERE latest.worker_id = w.id AND latest.is_revoked = 0)
      WHERE w.id = ?1 AND w.status != 'revoked'`,
  )
    .bind(workerId)
    .first<Record<string, unknown>>();
  if (!row)
    return json({ error: "Worker catalog entry not found" }, { status: 404 });
  return json({
    worker: {
      id: String(row.id),
      displayName: String(row.display_name),
      description: String(row.description ?? ""),
      publisher: String(row.publisher),
      status: String(row.status),
      latestVersion: row.version == null ? null : String(row.version),
      capabilities: parseJson(row.capabilities_json, []),
      credentialRequirements: parseJson(row.credential_requirements_json, []),
    },
  });
}

export async function handleSetWorkspaceWorkerAvailability(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  workerId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  authorize(context, "worker.manage_on_host");
  await requireWorkspaceContext(context, env, workspaceId);

  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  if (typeof body.enabled !== "boolean") {
    throw new HttpError(400, "enabled must be a boolean");
  }
  const requestedHostId =
    typeof body.hostId === "string" ? body.hostId : undefined;
  const requestedVersion =
    typeof body.version === "string" ? body.version : undefined;
  const worker = await env.CONCLAVE_DB.prepare(
    `SELECT w.id, wv.version
     FROM workers w
     JOIN worker_versions wv ON wv.worker_id = w.id AND wv.is_revoked = 0
     WHERE w.id = ?1 AND w.status = 'active'
       AND (?2 IS NULL OR wv.version = ?2)
     ORDER BY wv.created_at DESC LIMIT 1`,
  )
    .bind(workerId, requestedVersion ?? null)
    .first<{ id: string; version: string }>();
  if (!worker) {
    throw new HttpError(409, `Worker ${workerId} has no available version`);
  }

  const hosts = await env.CONCLAVE_DB.prepare(
    `SELECT h.id
     FROM hosts h
     JOIN host_workspace_bindings b ON b.host_id = h.id
       AND b.workspace_id = ?1 AND b.status = 'active'
     WHERE h.revoked_at IS NULL
       AND (?2 IS NULL OR h.id = ?2)
     ORDER BY h.id`,
  )
    .bind(workspaceId, requestedHostId ?? null)
    .all<{ id: string }>();
  if (requestedHostId && (hosts.results ?? []).length === 0) {
    return json({ error: "Host not found" }, { status: 404 });
  }

  const now = new Date().toISOString();
  for (const host of hosts.results ?? []) {
    const existing = await env.CONCLAVE_DB.prepare(
      "SELECT revision, release_channel, credential_setup_requests_json, local_permission_requests_json FROM host_desired_states WHERE host_id = ?1",
    )
      .bind(host.id)
      .first<{
        revision: number;
        release_channel: string;
        credential_setup_requests_json: string;
        local_permission_requests_json: string;
      }>();
    const revision = (existing?.revision ?? 0) + 1;
    const current = await env.CONCLAVE_DB.prepare(
      "SELECT worker_id, required_version FROM host_desired_workers WHERE host_id = ?1",
    )
      .bind(host.id)
      .all<{ worker_id: string; required_version: string }>();
    const desired = new Map(
      (current.results ?? []).map((row) => [
        row.worker_id,
        row.required_version,
      ]),
    );
    if (body.enabled) desired.set(workerId, worker.version);
    else desired.delete(workerId);

    const statements: D1PreparedStatement[] = [
      env.CONCLAVE_DB.prepare(
        `INSERT INTO host_desired_states
         (host_id, release_channel, credential_setup_requests_json,
          local_permission_requests_json, revision, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(host_id) DO UPDATE SET
           revision = excluded.revision, updated_at = excluded.updated_at`,
      ).bind(
        host.id,
        existing?.release_channel ?? "stable",
        existing?.credential_setup_requests_json ?? "[]",
        existing?.local_permission_requests_json ?? "[]",
        revision,
        now,
      ),
      env.CONCLAVE_DB.prepare(
        "DELETE FROM host_desired_workers WHERE host_id = ?1",
      ).bind(host.id),
    ];
    for (const [desiredWorkerId, desiredVersion] of desired) {
      statements.push(
        env.CONCLAVE_DB.prepare(
          `INSERT INTO host_desired_workers
           (host_id, worker_id, required_version, created_at, updated_at)
           VALUES (?1, ?2, ?3, ?4, ?4)`,
        ).bind(host.id, desiredWorkerId, desiredVersion, now),
      );
    }
    await env.CONCLAVE_DB.batch(statements);
  }

  await recordAudit(
    env,
    context,
    "host.worker.availability.updated",
    "worker",
    workerId,
    {
      enabled: body.enabled,
      hostId: requestedHostId ?? null,
      version: worker.version,
    },
  );
  return json({
    workerId,
    version: worker.version,
    enabled: body.enabled,
    hostIds: (hosts.results ?? []).map((host) => host.id),
    updatedAt: now,
  });
}

/** V5 Worker lifecycle boundary: only the execution Workspace owner may mutate it. */
export async function handleSetWorkspaceDesiredWorkerState(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  workerId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  await authorizeWorkspaceOwner(
    env.CONCLAVE_DB,
    context,
    workspaceId,
    "workers:manage",
  );
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  if (typeof body.enabled !== "boolean") {
    throw new HttpError(400, "enabled must be a boolean");
  }
  const requestedVersion =
    typeof body.version === "string" ? body.version : undefined;
  const worker = await env.CONCLAVE_DB.prepare(
    `SELECT w.id, wv.id AS workerVersionId, wv.version
     FROM workers w
     JOIN worker_versions wv ON wv.worker_id = w.id AND wv.is_revoked = 0
     WHERE w.id = ?1 AND w.status = 'active'
       AND (?2 IS NULL OR wv.version = ?2)
     ORDER BY wv.created_at DESC LIMIT 1`,
  )
    .bind(workerId, requestedVersion ?? null)
    .first<{ id: string; workerVersionId: string; version: string }>();
  if (!worker) {
    throw new HttpError(409, `Worker ${workerId} has no available version`);
  }

  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO workspace_worker_desired_state
       (workspace_id, worker_id, version_policy, enabled, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5)
     ON CONFLICT(workspace_id, worker_id) DO UPDATE SET
       version_policy = excluded.version_policy,
       enabled = excluded.enabled,
       updated_at = excluded.updated_at`,
  )
    .bind(workspaceId, workerId, worker.version, body.enabled ? 1 : 0, now)
    .run();

  await recordAudit(
    env,
    context,
    "workspace.worker.desired_state.updated",
    "worker",
    workerId,
    {
      workspaceId,
      enabled: body.enabled,
      version: worker.version,
    },
  );
  return json({
    workspaceId,
    workerId,
    version: worker.version,
    enabled: body.enabled,
    updatedAt: now,
  });
}

type CredentialProfileRow = {
  id: string;
  workspaceId: string;
  ownerType: "user" | "workspace";
  ownerId: string;
  workerId: string;
  workerName: string;
  hostId: string | null;
  hostName: string | null;
  displayName: string;
  authType: string;
  secretLocation: string;
  status: string;
  sharingPolicy: string;
  providerMetadataJson: string;
  concurrencyLimit: number | null;
  ownerName: string | null;
  lastUsedAt: string | null;
  usageCount: number;
  inputTokens: number;
  outputTokens: number;
  costMicros: number | null;
  durationMs: number;
};

function accountSharingLabel(policy: string): string {
  if (policy === "private_only") return "Private";
  if (policy === "workspace_capable") return "Workspace";
  return "Selected users";
}

function accountMetadata(row: CredentialProfileRow): Record<string, unknown> {
  return {
    id: row.id,
    workspaceId: row.workspaceId,
    displayName: row.displayName,
    workerId: row.workerId,
    worker: row.workerName,
    ownerType: row.ownerType,
    ownerId: row.ownerId,
    owner: row.ownerName ?? row.ownerId,
    hostId: row.hostId,
    host: row.hostName ?? (row.hostId ? "Host unavailable" : "No Host"),
    storageLocation:
      row.secretLocation === "host_secure_store" ? "Host secure store" : "None",
    authType: row.authType,
    status: row.status,
    sharingPolicy: row.sharingPolicy,
    sharing: accountSharingLabel(row.sharingPolicy),
    providerMetadata: parseJson(row.providerMetadataJson, {}),
    concurrencyLimit: row.concurrencyLimit,
    lastUsedAt: row.lastUsedAt,
    usage: {
      count: row.usageCount,
      inputTokens: row.inputTokens,
      outputTokens: row.outputTokens,
      costMicros: row.costMicros,
      durationMs: row.durationMs,
    },
  };
}

async function loadCredentialProfile(
  env: SecurityEnv,
  workspaceId: string,
  profileId: string,
): Promise<CredentialProfileRow | null> {
  return env.CONCLAVE_DB.prepare(
    `SELECT cp.id, cp.workspace_id as workspaceId,
            cp.owner_type as ownerType, cp.owner_id as ownerId,
            cp.worker_id as workerId, w.display_name as workerName,
            cp.host_id as hostId, h.name as hostName,
            cp.display_name as displayName, cp.auth_type as authType,
            cp.secret_location as secretLocation, cp.status,
            cp.sharing_policy as sharingPolicy,
            cp.provider_metadata_json as providerMetadataJson,
            cp.concurrency_limit as concurrencyLimit,
            CASE WHEN cp.owner_type = 'user' THEN u.display_name ELSE ws.name END as ownerName,
            MAX(us.recorded_at) as lastUsedAt,
            COUNT(us.id) as usageCount,
            COALESCE(SUM(us.input_tokens), 0) as inputTokens,
            COALESCE(SUM(us.output_tokens), 0) as outputTokens,
            SUM(us.cost_micros) as costMicros,
            COALESCE(SUM(us.duration_ms), 0) as durationMs
     FROM credential_profiles cp
     JOIN workers w ON w.id = cp.worker_id
     LEFT JOIN hosts h ON h.id = cp.host_id
     LEFT JOIN users u ON cp.owner_type = 'user' AND u.id = cp.owner_id
     LEFT JOIN workspaces ws ON cp.owner_type = 'workspace' AND ws.id = cp.owner_id
     LEFT JOIN usage us ON us.credential_profile_id = cp.id
     WHERE cp.id = ?1 AND cp.workspace_id = ?2
     GROUP BY cp.id`,
  )
    .bind(profileId, workspaceId)
    .first<CredentialProfileRow>();
}

async function authorizeCredentialProfileOwner(
  env: SecurityEnv,
  context: SecurityContext,
  profileId: string,
  permission: Permission,
): Promise<CredentialProfileRow> {
  const profile = await loadCredentialProfile(
    env,
    context.workspaceId,
    profileId,
  );
  if (!profile) throw new HttpError(404, "Account not found");
  if (profile.ownerType === "user" && profile.ownerId === context.userId) {
    return profile;
  }
  authorize(context, permission);
  return profile;
}

function v5AccountMetadata(
  row: Record<string, unknown>,
): Record<string, unknown> {
  return {
    id: String(row.id),
    ownerUserId: String(row.owner_user_id),
    workerId: String(row.worker_id),
    executionWorkspaceId: row.execution_workspace_id ?? null,
    displayName: String(row.display_name),
    authType: String(row.auth_type),
    status: String(row.status),
    sharingMode: String(row.sharing_mode),
    providerMetadata: parseJson(String(row.provider_metadata_json ?? "{}"), {}),
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

async function loadV5Account(
  env: SecurityEnv,
  accountId: string,
): Promise<Record<string, unknown> | null> {
  return env.CONCLAVE_DB.prepare(
    `SELECT id, owner_user_id, worker_id, execution_workspace_id, display_name,
            auth_type, status, sharing_mode, provider_metadata_json,
            created_at, updated_at
     FROM ai_accounts WHERE id = ?1`,
  )
    .bind(accountId)
    .first<Record<string, unknown>>();
}

async function authorizeV5AccountOwner(
  env: SecurityEnv,
  context: SecurityContext,
  accountId: string,
): Promise<Record<string, unknown>> {
  const account = await loadV5Account(env, accountId);
  if (!account || String(account.owner_user_id) !== context.userId) {
    throw new HttpError(404, "Account not found");
  }
  return account;
}

async function handleListV5Accounts(
  request: Request,
  env: SecurityEnv,
  context: SecurityContext,
): Promise<Response> {
  const projectId = new URL(request.url).searchParams.get("projectId");
  let rows;
  if (projectId) {
    await authorizeProjectMembership(
      env.CONCLAVE_DB,
      context,
      projectId,
      "projects:read",
    );
    rows = await env.CONCLAVE_DB.prepare(
      `SELECT DISTINCT a.* FROM ai_accounts a
       LEFT JOIN project_account_grants pag ON pag.account_id = a.id
        AND pag.project_id = ?1 AND pag.status = 'active'
        AND (pag.grantee_user_id IS NULL OR pag.grantee_user_id = ?2)
       WHERE a.owner_user_id = ?2 OR pag.id IS NOT NULL
       ORDER BY a.display_name`,
    )
      .bind(projectId, context.userId)
      .all<Record<string, unknown>>();
  } else {
    rows = await env.CONCLAVE_DB.prepare(
      `SELECT * FROM ai_accounts WHERE owner_user_id = ?1 ORDER BY display_name`,
    )
      .bind(context.userId)
      .all<Record<string, unknown>>();
  }
  return json({ accounts: (rows.results ?? []).map(v5AccountMetadata) });
}

async function handleCreateV5Account(
  request: Request,
  env: SecurityEnv,
  context: SecurityContext,
  workspaceId: string,
): Promise<Response> {
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const displayName = requiredString(body.displayName, "displayName");
  const workerId = requiredString(body.workerId, "workerId");
  const authType = String(body.authType ?? "none");
  const sharingMode = String(body.sharingMode ?? "private_only");
  if (
    !["none", "api_key", "oauth", "session_token", "local"].includes(authType)
  ) {
    throw new HttpError(400, "Unsupported Account authentication type");
  }
  if (!["private_only", "project_shared"].includes(sharingMode)) {
    throw new HttpError(400, "Unsupported Account sharing mode");
  }
  const providerMetadata = assertSafeProviderMetadata(body.providerMetadata);
  if (
    sharingMode === "project_shared" &&
    providerMetadata.providerSharingPolicy === "private_only"
  ) {
    throw new HttpError(409, "Provider policy does not allow Account sharing");
  }
  if (workspaceId) {
    await authorizeWorkspaceOwner(
      env.CONCLAVE_DB,
      context,
      workspaceId,
      "workspace:manage",
    );
  }
  const worker = await env.CONCLAVE_DB.prepare(
    "SELECT id FROM workers WHERE id = ?1 AND status <> 'revoked'",
  )
    .bind(workerId)
    .first<{ id: string }>();
  if (!worker) throw new HttpError(404, "Worker not found");
  const id = `account-${crypto.randomUUID().slice(0, 16)}`;
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO ai_accounts
       (id, owner_user_id, worker_id, execution_workspace_id, display_name,
        auth_type, secret_location, secret_reference, status, sharing_mode,
        provider_metadata_json, created_at, updated_at)
     VALUES (?1, ?2, ?3, NULLIF(?4, ''), ?5, ?6,
        CASE WHEN ?6 = 'none' THEN 'none' ELSE 'workspace_secure_store' END,
        NULL, CASE WHEN ?6 = 'none' THEN 'ready' ELSE 'setup_required' END,
        ?7, ?8, ?9, ?9)`,
  )
    .bind(
      id,
      context.userId,
      workerId,
      workspaceId,
      displayName,
      authType,
      sharingMode,
      JSON.stringify(providerMetadata),
      now,
    )
    .run();
  await recordAudit(env, context, "ai_account.created", "ai_account", id, {
    workerId,
    executionWorkspaceId: workspaceId || null,
    sharingMode,
  });
  const account = await loadV5Account(env, id);
  return json(
    { account: account ? v5AccountMetadata(account) : { id } },
    { status: 201 },
  );
}

async function handleUpdateV5Account(
  request: Request,
  env: SecurityEnv,
  context: SecurityContext,
  accountId: string,
): Promise<Response> {
  const account = await authorizeV5AccountOwner(env, context, accountId);
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const displayName = body.displayName;
  const sharingMode = body.sharingMode;
  if (displayName !== undefined && typeof displayName !== "string")
    throw new HttpError(400, "displayName must be a string");
  if (
    sharingMode !== undefined &&
    !["private_only", "project_shared"].includes(String(sharingMode))
  )
    throw new HttpError(400, "Unsupported Account sharing mode");
  const metadata = assertSafeProviderMetadata(body.providerMetadata);
  const currentMetadata = parseJson<Record<string, unknown>>(
    String(account.provider_metadata_json ?? "{}"),
    {},
  );
  const mergedMetadata = { ...currentMetadata, ...metadata };
  if (
    sharingMode === "project_shared" &&
    mergedMetadata.providerSharingPolicy === "private_only"
  )
    throw new HttpError(409, "Provider policy does not allow Account sharing");
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `UPDATE ai_accounts SET display_name = COALESCE(?1, display_name),
       sharing_mode = COALESCE(?2, sharing_mode), provider_metadata_json = ?3,
       updated_at = ?4 WHERE id = ?5 AND owner_user_id = ?6`,
  )
    .bind(
      displayName ?? null,
      sharingMode ?? null,
      JSON.stringify(mergedMetadata),
      now,
      accountId,
      context.userId,
    )
    .run();
  return json({
    account: v5AccountMetadata(
      (await loadV5Account(env, accountId)) ?? account,
    ),
  });
}

async function handleRevokeV5Account(
  env: SecurityEnv,
  context: SecurityContext,
  accountId: string,
): Promise<Response> {
  await authorizeV5AccountOwner(env, context, accountId);
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    "UPDATE ai_accounts SET status = 'revoked', updated_at = ?1 WHERE id = ?2 AND owner_user_id = ?3",
  )
    .bind(now, accountId, context.userId)
    .run();
  await env.CONCLAVE_DB.prepare(
    "UPDATE project_account_grants SET status = 'revoked' WHERE account_id = ?1 AND status = 'active'",
  )
    .bind(accountId)
    .run();
  return json({ ok: true, revokedAt: now });
}

async function handleCreateV5AccountSetupIntent(
  request: Request,
  env: SecurityEnv,
  context: SecurityContext,
  workspaceId: string,
  accountId: string,
): Promise<Response> {
  const account = await loadV5Account(env, accountId);
  if (!account) throw new HttpError(404, "Account not found");
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const targetWorkspaceId =
    workspaceId ||
    requiredString(body.executionWorkspaceId, "executionWorkspaceId");
  const action = String(body.action ?? "setup");
  if (action === "approve") {
    const intentId = requiredString(body.intentId, "intentId");
    await authorizeWorkspaceOwner(
      env.CONCLAVE_DB,
      context,
      targetWorkspaceId,
      "workspace:manage",
    );
    const now = new Date().toISOString();
    await env.CONCLAVE_DB.prepare(
      `UPDATE ai_account_setup_intents SET status = 'approved', approved_by_user_id = ?1, approved_at = ?2
       WHERE id = ?3 AND account_id = ?4 AND execution_workspace_id = ?5 AND status = 'requested'`,
    )
      .bind(context.userId, now, intentId, accountId, targetWorkspaceId)
      .run();
    await env.CONCLAVE_DB.prepare(
      "UPDATE ai_accounts SET execution_workspace_id = ?1, updated_at = ?2 WHERE id = ?3",
    )
      .bind(targetWorkspaceId, now, accountId)
      .run();
    return json({
      setupIntent: {
        id: intentId,
        accountId,
        workspaceId: targetWorkspaceId,
        status: "approved",
        approvedAt: now,
      },
    });
  }
  if (String(account.owner_user_id) !== context.userId)
    throw new HttpError(404, "Account not found");
  const workspace = await env.CONCLAVE_DB.prepare(
    "SELECT id FROM execution_workspaces WHERE id = ?1 AND status <> 'revoked'",
  )
    .bind(targetWorkspaceId)
    .first();
  if (!workspace) throw new HttpError(404, "Workspace not found");
  if (!["setup", "reauthenticate", "clear"].includes(action))
    throw new HttpError(400, "Unsupported Account setup action");
  const id = `account-setup-${crypto.randomUUID().slice(0, 16)}`;
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO ai_account_setup_intents
       (id, account_id, execution_workspace_id, requested_by_user_id, action, requested_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
  )
    .bind(id, accountId, targetWorkspaceId, context.userId, action, now)
    .run();
  return json(
    {
      setupIntent: {
        id,
        accountId,
        workspaceId: targetWorkspaceId,
        action,
        status: "requested",
        requestedAt: now,
      },
    },
    { status: 202 },
  );
}

async function handleCreateV5AccountGrant(
  request: Request,
  env: SecurityEnv,
  context: SecurityContext,
  accountId: string,
): Promise<Response> {
  await authorizeV5AccountOwner(env, context, accountId);
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const projectId = requiredString(body.projectId, "projectId");
  const granteeUserId =
    body.granteeUserId == null
      ? null
      : requiredString(body.granteeUserId, "granteeUserId");
  await authorizeProjectOwner(env.CONCLAVE_DB, context, projectId);
  if (granteeUserId) {
    const member = await env.CONCLAVE_DB.prepare(
      "SELECT user_id FROM project_memberships WHERE project_id = ?1 AND user_id = ?2",
    )
      .bind(projectId, granteeUserId)
      .first();
    if (!member)
      throw new HttpError(404, "Selected user is not a Project member");
  }
  const id = `account-grant-${crypto.randomUUID().slice(0, 16)}`;
  const now = new Date().toISOString();
  const expiresAt = typeof body.expiresAt === "string" ? body.expiresAt : null;
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO project_account_grants (id, project_id, account_id, granted_by_user_id, grantee_user_id, expires_at, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
     ON CONFLICT(project_id, account_id, grantee_user_id) DO UPDATE SET status = 'active', granted_by_user_id = excluded.granted_by_user_id, expires_at = excluded.expires_at`,
  )
    .bind(
      id,
      projectId,
      accountId,
      context.userId,
      granteeUserId,
      expiresAt,
      now,
    )
    .run();
  return json(
    {
      grant: {
        id,
        projectId,
        accountId,
        granteeUserId,
        expiresAt,
        status: "active",
      },
    },
    { status: 201 },
  );
}

async function handleRevokeV5AccountGrant(
  env: SecurityEnv,
  context: SecurityContext,
  accountId: string,
  grantId: string,
): Promise<Response> {
  await authorizeV5AccountOwner(env, context, accountId);
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    "UPDATE project_account_grants SET status = 'revoked' WHERE id = ?1 AND account_id = ?2",
  )
    .bind(grantId, accountId)
    .run();
  return json({ ok: true, revokedAt: now });
}

function v5GrantMetadata(
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
    scope: String(row.scope),
    repositoryMappings: parseJson(row.repository_mappings_json, []),
    pathMappings: parseJson(row.path_mappings_json, []),
    allowedWorkerIds: parseJson(row.allowed_worker_ids_json, []),
    allowedWorkerCapabilities: parseJson(
      row.allowed_worker_capabilities_json,
      [],
    ),
    allowedPermissions: parseJson(row.allowed_permissions_json, []),
    networkPolicy: parseJson(row.network_policy_json, {}),
    concurrency: parseJson(row.concurrency_json, {}),
    budget: parseJson(row.budget_json, null),
    requiresStepUp: Boolean(row.requires_step_up),
    expiresAt: row.expires_at ?? null,
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

async function loadV5Grant(
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

function grantJsonArray(value: unknown, field: string): string {
  if (value === undefined) return "[]";
  if (
    !Array.isArray(value) ||
    value.some((item) => typeof item !== "object" || item === null)
  ) {
    throw new HttpError(400, `${field} must be an array of objects`);
  }
  return JSON.stringify(value);
}

function grantStringArray(value: unknown, field: string): string {
  if (value === undefined) return "[]";
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new HttpError(400, `${field} must be an array of strings`);
  }
  return JSON.stringify(value);
}

async function grantStepUpIfRequired(
  env: SecurityEnv,
  context: SecurityContext,
  scope: string,
  body: Record<string, unknown>,
): Promise<number> {
  if (scope !== "full_workspace") return 0;
  if (body.confirmFullWorkspace !== true) {
    throw new HttpError(
      400,
      "Full Workspace access requires explicit confirmation",
    );
  }
  const verified = await hasRecentStepUp(
    env.CONCLAVE_DB,
    context.userId,
    context.sessionId,
    SENSITIVE_OPERATIONS.fullWorkspaceGrant,
  );
  if (!verified)
    throw new HttpError(428, "Recent step-up authentication is required");
  return 1;
}

async function createV5WorkspaceProjectGrant(
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
  const scope = String(body.scope ?? "project_repository");
  if (
    !["project_repository", "selected_paths", "full_workspace"].includes(scope)
  ) {
    throw new HttpError(400, "Unsupported Workspace Project Grant scope");
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
  if (
    membership?.role === "collaborator" &&
    body.confirmContribution !== true
  ) {
    throw new HttpError(
      400,
      "Collaborators must explicitly confirm Workspace contribution",
    );
  }
  const requiresStepUp = await grantStepUpIfRequired(env, context, scope, body);
  const repositoryMappings = grantJsonArray(
    body.repositoryMappings,
    "repositoryMappings",
  );
  const pathMappings = grantJsonArray(body.pathMappings, "pathMappings");
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
       (id, project_id, workspace_id, granted_by_user_id, status, scope,
        repository_mappings_json, path_mappings_json, allowed_worker_ids_json,
        allowed_worker_capabilities_json, allowed_permissions_json,
        network_policy_json, concurrency_json, budget_json, requires_step_up,
        expires_at, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, 'active', ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?16)
     ON CONFLICT(id, project_id, workspace_id) DO NOTHING`,
  )
    .bind(
      id,
      projectId,
      workspaceId,
      context.userId,
      scope,
      repositoryMappings,
      pathMappings,
      allowedWorkerIds,
      allowedWorkerCapabilities,
      allowedPermissions,
      networkPolicy,
      concurrency,
      budget,
      requiresStepUp,
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
      scope,
      requiresStepUp: Boolean(requiresStepUp),
    },
  );
  const grant = await loadV5Grant(env, id);
  return json(
    {
      grant: grant
        ? v5GrantMetadata(grant)
        : { id, projectId, workspaceId, scope },
    },
    { status: 201 },
  );
}

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
  return json({ grants: (rows.results ?? []).map(v5GrantMetadata) });
}

export async function handleCreateWorkspaceProjectGrant(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  projectId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  return createV5WorkspaceProjectGrant(
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
  return json({ workspaces: (rows.results ?? []).map(v5GrantMetadata) });
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
  return createV5WorkspaceProjectGrant(
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
  const existing = await loadV5Grant(env, grantId);
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
  const updated = await loadV5Grant(env, grantId);
  return json({ grant: updated ? v5GrantMetadata(updated) : null });
}

export async function handleRevokeWorkspaceProjectGrant(
  request: Request,
  env: SecurityEnv,
  grantId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const existing = await loadV5Grant(env, grantId);
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

function assertSafeProviderMetadata(value: unknown): Record<string, unknown> {
  if (value === undefined) return {};
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(400, "providerMetadata must be an object");
  }
  const forbidden = /secret|token|password|api[_-]?key|private/i;
  const metadata = value as Record<string, unknown>;
  if (Object.keys(metadata).some((key) => forbidden.test(key))) {
    throw new HttpError(400, "providerMetadata cannot contain credentials");
  }
  return metadata;
}

async function handleListCredentialProfiles(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (context.authorizationModel === "v5") {
    return handleListV5Accounts(request, env, context);
  }
  authorize(context, "credential.use");
  await requireWorkspaceContext(context, env, workspaceId);
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT cp.id FROM credential_profiles cp
     WHERE cp.workspace_id = ?1 AND cp.status <> 'revoked'
     ORDER BY cp.display_name`,
  )
    .bind(workspaceId)
    .all<{ id: string }>();
  const accounts = [];
  for (const row of rows.results ?? []) {
    const profile = await loadCredentialProfile(env, workspaceId, row.id);
    if (!profile) continue;
    try {
      await authorizeCredentialProfileUse(env.CONCLAVE_DB, context, row.id);
      accounts.push(accountMetadata(profile));
    } catch {
      // Account metadata is visible only to the owner or an authorized user.
    }
  }
  return json({ accounts });
}

async function handleCreateCredentialProfile(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (context.authorizationModel === "v5") {
    return handleCreateV5Account(request, env, context, workspaceId);
  }
  authorize(context, "credential.create");
  await requireWorkspaceContext(context, env, workspaceId);
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const displayName = requiredString(body.displayName, "displayName");
  const workerId = requiredString(body.workerId, "workerId");
  const authType = body.authType ?? "none";
  const ownerType = body.ownerType ?? "user";
  const sharingPolicy = body.sharingPolicy ?? "private_only";
  const hostId = typeof body.hostId === "string" ? body.hostId : null;
  if (
    ![
      "none",
      "api_key",
      "oauth_browser",
      "local_cli_session",
      "interactive_custom",
    ].includes(String(authType)) ||
    !["user", "workspace"].includes(String(ownerType)) ||
    !["private_only", "owner_controlled", "workspace_capable"].includes(
      String(sharingPolicy),
    )
  ) {
    throw new HttpError(400, "Unsupported Account configuration");
  }
  if (ownerType === "workspace") {
    authorize(context, "credential.share");
  }
  const ownerId = ownerType === "workspace" ? workspaceId : context.userId;
  if (hostId) {
    const host = await env.CONCLAVE_DB.prepare(
      `SELECT h.id FROM hosts h
       JOIN host_workspace_bindings b ON b.host_id = h.id
        AND b.workspace_id = ?2 AND b.status = 'active'
       WHERE h.id = ?1 AND h.revoked_at IS NULL`,
    )
      .bind(hostId, workspaceId)
      .first<{ id: string }>();
    if (!host) throw new HttpError(404, "Host not found");
  } else if (authType !== "none") {
    throw new HttpError(400, "A Host is required for local Account storage");
  }
  const worker = await env.CONCLAVE_DB.prepare(
    "SELECT id FROM workers WHERE id = ?1 AND status <> 'revoked'",
  )
    .bind(workerId)
    .first<{ id: string }>();
  if (!worker) throw new HttpError(404, "Worker not found");
  const providerMetadata = assertSafeProviderMetadata(body.providerMetadata);
  const id = `cred-${crypto.randomUUID().slice(0, 16)}`;
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO credential_profiles
       (id, workspace_id, owner_type, owner_id, worker_id, host_id,
        display_name, auth_type, secret_location, secret_reference, status,
        sharing_policy, provider_metadata_json, concurrency_limit,
        created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10,
             CASE WHEN ?8 = 'none' THEN 'ready' ELSE 'setup_required' END,
             ?11, ?12, ?13, ?14, ?14)`,
  )
    .bind(
      id,
      workspaceId,
      ownerType,
      ownerId,
      workerId,
      hostId,
      displayName,
      authType,
      authType === "none" ? "none" : "host_secure_store",
      hostId ? `credential-profile/${hostId}/${workerId}/${id}` : null,
      sharingPolicy,
      JSON.stringify(providerMetadata),
      typeof body.concurrencyLimit === "number" ? body.concurrencyLimit : null,
      now,
    )
    .run();
  await recordAudit(
    env,
    context,
    "credential_profile.created",
    "credential_profile",
    id,
    {
      workerId,
      ownerType,
      hostId,
    },
  );
  const profile = await loadCredentialProfile(env, workspaceId, id);
  return json(
    { account: profile ? accountMetadata(profile) : { id } },
    { status: 201 },
  );
}

async function handleUpdateCredentialProfile(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  profileId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (context.authorizationModel === "v5") {
    return handleUpdateV5Account(request, env, context, profileId);
  }
  await requireWorkspaceContext(context, env, workspaceId);
  const profile = await authorizeCredentialProfileOwner(
    env,
    context,
    profileId,
    "credential.share",
  );
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const sharingPolicy = body.sharingPolicy;
  if (
    sharingPolicy !== undefined &&
    !["private_only", "owner_controlled", "workspace_capable"].includes(
      String(sharingPolicy),
    )
  ) {
    throw new HttpError(400, "Unsupported sharing policy");
  }
  const displayName = body.displayName;
  if (displayName !== undefined && typeof displayName !== "string") {
    throw new HttpError(400, "displayName must be a string");
  }
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `UPDATE credential_profiles
     SET display_name = COALESCE(?1, display_name),
         sharing_policy = COALESCE(?2, sharing_policy), updated_at = ?3
     WHERE id = ?4 AND workspace_id = ?5`,
  )
    .bind(
      displayName ?? null,
      sharingPolicy ?? null,
      now,
      profile.id,
      workspaceId,
    )
    .run();
  const updated = await loadCredentialProfile(env, workspaceId, profileId);
  await recordAudit(
    env,
    context,
    "credential_profile.updated",
    "credential_profile",
    profileId,
    {
      sharingPolicy: sharingPolicy ?? profile.sharingPolicy,
    },
  );
  return json({ account: updated ? accountMetadata(updated) : null });
}

async function handleRevokeCredentialProfile(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  profileId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (context.authorizationModel === "v5") {
    return handleRevokeV5Account(env, context, profileId);
  }
  await requireWorkspaceContext(context, env, workspaceId);
  await authorizeCredentialProfileOwner(
    env,
    context,
    profileId,
    "credential.share",
  );
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    "UPDATE credential_profiles SET status = 'revoked', updated_at = ?1 WHERE id = ?2 AND workspace_id = ?3",
  )
    .bind(now, profileId, workspaceId)
    .run();
  await recordAudit(
    env,
    context,
    "credential_profile.revoked",
    "credential_profile",
    profileId,
  );
  return json({ ok: true, revokedAt: now });
}

async function handleCreateCredentialSetupIntent(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  profileId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (context.authorizationModel === "v5") {
    return handleCreateV5AccountSetupIntent(
      request,
      env,
      context,
      workspaceId,
      profileId,
    );
  }
  await requireWorkspaceContext(context, env, workspaceId);
  const profile = await authorizeCredentialProfileOwner(
    env,
    context,
    profileId,
    "credential.use",
  );
  if (!profile.hostId)
    return json(
      { error: "This Account does not require Host-local setup" },
      { status: 400 },
    );
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const action = body.action ?? "setup";
  if (!["setup", "reauthenticate", "clear"].includes(String(action))) {
    throw new HttpError(400, "Unsupported Account setup action");
  }
  const id = `setup-${crypto.randomUUID().slice(0, 16)}`;
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO credential_setup_intents
       (id, credential_profile_id, workspace_id, host_id, requested_by_user_id,
        action, requested_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
  )
    .bind(
      id,
      profileId,
      workspaceId,
      profile.hostId,
      context.userId,
      action,
      now,
    )
    .run();
  await recordAudit(
    env,
    context,
    "credential_profile.setup_requested",
    "credential_profile",
    profileId,
    {
      action,
      hostId: profile.hostId,
    },
  );
  return json(
    {
      setupIntent: {
        id,
        profileId,
        hostId: profile.hostId,
        action,
        status: "requested",
        requestedAt: now,
      },
    },
    { status: 202 },
  );
}

async function handleCreateCredentialGrant(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  profileId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (context.authorizationModel === "v5") {
    return handleCreateV5AccountGrant(request, env, context, profileId);
  }
  await requireWorkspaceContext(context, env, workspaceId);
  const profile = await authorizeCredentialProfileOwner(
    env,
    context,
    profileId,
    "credential.share",
  );
  if (profile.sharingPolicy === "private_only") {
    throw new HttpError(409, "Private Accounts cannot be shared");
  }
  const body = (await request.json().catch(() => ({}))) as Record<
    string,
    unknown
  >;
  const granteeType = body.granteeType;
  const granteeId = requiredString(body.granteeId, "granteeId");
  if (!["user", "workspace", "role"].includes(String(granteeType))) {
    throw new HttpError(400, "Unsupported Account grantee type");
  }
  if (granteeType === "workspace" && granteeId !== workspaceId) {
    throw new HttpError(400, "Account grants cannot target another Workspace");
  }
  if (granteeType === "user") {
    const user = await env.CONCLAVE_DB.prepare(
      `SELECT user_id FROM workspace_memberships
       WHERE workspace_id = ?1 AND user_id = ?2 AND status = 'active'`,
    )
      .bind(workspaceId, granteeId)
      .first<{ user_id: string }>();
    if (!user)
      throw new HttpError(404, "Selected user is not a Workspace member");
  }
  const id = `grant-${crypto.randomUUID().slice(0, 16)}`;
  const now = new Date().toISOString();
  const expiresAt = typeof body.expiresAt === "string" ? body.expiresAt : null;
  const usageLimit =
    typeof body.usageLimit === "number" ? body.usageLimit : null;
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO credential_grants
       (id, credential_profile_id, workspace_id, grantee_type, grantee_id,
        use_permission, granted_by_user_id, created_at, expires_at, usage_limit)
     VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6, ?7, ?8, ?9)
     ON CONFLICT(credential_profile_id, grantee_type, grantee_id) DO UPDATE SET
       use_permission = 1, granted_by_user_id = excluded.granted_by_user_id,
       expires_at = excluded.expires_at, usage_limit = excluded.usage_limit,
       revoked_at = NULL`,
  )
    .bind(
      id,
      profileId,
      workspaceId,
      granteeType,
      granteeId,
      context.userId,
      now,
      expiresAt,
      usageLimit,
    )
    .run();
  await recordAudit(
    env,
    context,
    "credential_profile.grant.created",
    "credential_profile",
    profileId,
    {
      granteeType,
      granteeId,
      expiresAt,
    },
  );
  return json(
    { grant: { id, profileId, granteeType, granteeId, expiresAt, usageLimit } },
    { status: 201 },
  );
}

async function handleRevokeCredentialGrant(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  profileId: string,
  grantId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  if (context.authorizationModel === "v5") {
    return handleRevokeV5AccountGrant(env, context, profileId, grantId);
  }
  await requireWorkspaceContext(context, env, workspaceId);
  await authorizeCredentialProfileOwner(
    env,
    context,
    profileId,
    "credential.share",
  );
  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `UPDATE credential_grants SET revoked_at = ?1
     WHERE id = ?2 AND credential_profile_id = ?3 AND workspace_id = ?4`,
  )
    .bind(now, grantId, profileId, workspaceId)
    .run();
  await recordAudit(
    env,
    context,
    "credential_profile.grant.revoked",
    "credential_profile",
    profileId,
    {
      grantId,
    },
  );
  return json({ ok: true, revokedAt: now });
}

async function handleDispatchTaskAssignment(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  taskId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, ctx);
  const body = ((await request.json().catch(() => ({}))) || {}) as Record<
    string,
    unknown
  >;

  if (context.authorizationModel === "v5") {
    const taskRow = await env.CONCLAVE_DB.prepare(
      `SELECT t.id, t.phase_id as phaseId, t.role, t.objective,
              t.capabilities_json as capabilitiesJson,
              ph.run_id as runId, r.project_id as projectId
       FROM tasks t JOIN phases ph ON ph.id = t.phase_id
       JOIN runs r ON r.id = ph.run_id WHERE t.id = ?1`,
    )
      .bind(taskId)
      .first<Record<string, unknown>>();
    if (!taskRow) return json({ error: "Task not found" }, { status: 404 });
    const projectId = String(taskRow.projectId);
    await authorizeProjectMembership(
      env.CONCLAVE_DB,
      context,
      projectId,
      "runs:control",
    );
    const task: TaskToDispatch = {
      id: String(taskRow.id),
      role:
        typeof body.role === "string"
          ? body.role
          : String(taskRow.role ?? "implementer"),
      objective:
        typeof body.objective === "string"
          ? body.objective
          : String(taskRow.objective ?? ""),
      capabilities: Array.isArray(body.capabilities)
        ? body.capabilities.filter(
            (value): value is string => typeof value === "string",
          )
        : parseJson(taskRow.capabilitiesJson, []),
      input:
        typeof body.input === "object" && body.input !== null
          ? (body.input as Record<string, unknown>)
          : undefined,
      contextArtifactIds: Array.isArray(body.contextArtifactIds)
        ? body.contextArtifactIds.filter(
            (value): value is string => typeof value === "string",
          )
        : undefined,
      timeoutMs:
        typeof body.timeoutMs === "number" ? body.timeoutMs : undefined,
      projectId,
      requestedByUserId: context.userId,
      accountId:
        typeof body.accountId === "string" ? body.accountId : undefined,
      model: typeof body.model === "string" ? body.model : undefined,
    };
    const result = await dispatchTaskAssignment(
      env as unknown as AssignmentDispatcherEnv,
      {
        workspaceId:
          typeof body.workspaceId === "string" ? body.workspaceId : workspaceId,
        runId: String(taskRow.runId),
        taskId,
        task,
        explicitWorkerId:
          typeof body.workerId === "string" ? body.workerId : undefined,
        excludeIndependenceKeys: Array.isArray(body.excludeIndependenceKeys)
          ? body.excludeIndependenceKeys.filter(
              (value): value is string => typeof value === "string",
            )
          : undefined,
      },
    );
    return result.status === "failed"
      ? json(
          {
            error: result.error || "Failed to dispatch task assignment",
            assignment: result,
          },
          { status: 422 },
        )
      : json({ assignment: result });
  }

  authorize(context, "runs:control");
  authorize(context, "host.use");
  await requireWorkspaceContext(context, env, workspaceId);

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
  await requireWorkspaceContext(context, env, workspaceId);

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
  authorize(context, "host.use");
  await requireWorkspaceContext(context, env, workspaceId);

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

async function handleWorkspaceGatewayConnect(
  request: Request,
  env: SecurityEnv,
): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    return json({ error: "Expected WebSocket upgrade" }, { status: 426 });
  }

  const url = new URL(request.url);
  const workspaceRuntimeId = url.searchParams.get("workspaceRuntimeId");
  const authToken =
    extractBearerToken(request.headers) ??
    url.searchParams.get("token") ??
    url.searchParams.get("authToken");

  if (!workspaceRuntimeId || !authToken) {
    return json(
      { error: "workspaceRuntimeId and authToken are required" },
      { status: 401 },
    );
  }

  const tokenHash = await hashToken(authToken);
  const workspace = await env.CONCLAVE_DB.prepare(
    `SELECT wri.workspace_id AS workspaceId
     FROM workspace_runtime_identities wri
     JOIN execution_workspaces ew ON ew.id = wri.workspace_id
     WHERE wri.id = ?1 AND wri.credential_token_hash = ?2
       AND wri.revoked_at IS NULL AND ew.status <> 'revoked'`,
  )
    .bind(workspaceRuntimeId, tokenHash)
    .first<{ workspaceId: string }>();

  if (!workspace) {
    return json(
      { error: "Invalid or revoked Workspace runtime credential" },
      { status: 401 },
    );
  }

  const targetUrl = new URL(request.url);
  targetUrl.searchParams.set("workspaceRuntimeId", workspaceRuntimeId);
  const upgradedRequest = new Request(targetUrl.toString(), request);

  if (!env.CONCLAVE_WORKSPACE_GATEWAY) {
    return json(
      { error: "Workspace Gateway is not configured" },
      { status: 503 },
    );
  }
  const stub = env.CONCLAVE_WORKSPACE_GATEWAY.getByName(workspace.workspaceId);
  return stub.fetch(upgradedRequest);
}

async function handleHostProtocolMessage(
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
          err instanceof Error ? err.message : "Invalid host protocol message",
      },
      { status: 400 },
    );
  }

  const token = extractBearerToken(request.headers);
  let authenticatedHost: { id: string; workspace_id: string } | null = null;
  if (token) {
    const tokenHash = await hashToken(token);
    const messageEnvelope = message as unknown as {
      workspaceId?: unknown;
      payload?: Record<string, unknown>;
    };
    const messageWorkspaceId =
      typeof messageEnvelope.workspaceId === "string"
        ? messageEnvelope.workspaceId
        : typeof messageEnvelope.payload?.workspaceId === "string"
          ? messageEnvelope.payload.workspaceId
          : null;
    if (!messageWorkspaceId) {
      return json(
        { error: "Host workspace context is required" },
        { status: 400 },
      );
    }
    authenticatedHost = await env.CONCLAVE_DB.prepare(
      `SELECT h.id, b.workspace_id FROM hosts h
       JOIN host_workspace_bindings b ON b.host_id = h.id
       WHERE h.auth_token_hash = ?1 AND b.workspace_id = ?2
         AND b.status = 'active' AND h.revoked_at IS NULL`,
    )
      .bind(tokenHash, messageWorkspaceId)
      .first<{ id: string; workspace_id: string }>();
    if (!authenticatedHost) {
      return json({ error: "Unauthorized host token" }, { status: 401 });
    }
  } else if (!testAuthenticationEnabled(env)) {
    return json({ error: "Host authentication required" }, { status: 401 });
  }

  if (
    authenticatedHost &&
    (message.type === "agent.hello" ||
      message.type === "agent.heartbeat" ||
      message.type === "agent.sync.request") &&
    (message.payload.agentId !== authenticatedHost.id ||
      message.payload.workspaceId !== authenticatedHost.workspace_id)
  ) {
    return json({ error: "Host identity mismatch" }, { status: 403 });
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
    const assignmentStates: Array<{
      assignmentId: string;
      attemptId: string;
      idempotencyKey: string;
      status: string;
    }> = [];
    const syncPayload = message.payload as unknown as Record<string, unknown>;
    const assignmentIds = Array.isArray(syncPayload.unreconciledAssignmentIds)
      ? syncPayload.unreconciledAssignmentIds.filter(
          (value): value is string => typeof value === "string",
        )
      : [];
    if (assignmentIds.length > 0) {
      const placeholders = assignmentIds
        .map((_: unknown, index: number) => `?${index + 3}`)
        .join(",");
      const rows = await env.CONCLAVE_DB.prepare(
        `SELECT id, attempt_id, idempotency_key, status
         FROM worker_assignments
         WHERE host_id = ?1 AND workspace_id = ?2 AND id IN (${placeholders})`,
      )
        .bind(
          message.payload.agentId,
          message.payload.workspaceId,
          ...assignmentIds,
        )
        .all<{
          id: string;
          attempt_id: string;
          idempotency_key: string;
          status: string;
        }>();
      for (const row of rows.results ?? []) {
        assignmentStates.push({
          assignmentId: row.id,
          attemptId: row.attempt_id,
          idempotencyKey: row.idempotency_key,
          status: row.status,
        });
      }
    }
    const desiredWorkerRows = await env.CONCLAVE_DB.prepare(
      `SELECT id, workspace_id, host_id, plugin_id, plugin_version_policy,
              name, roles_json, capabilities_json, config_json, secret_refs_json,
              billing_mode, cost_metadata_json, independence_key,
              concurrency_limit, session_policy, enabled
       FROM workers
       WHERE workspace_id = ?1 AND host_id = ?2 AND enabled = 1
       ORDER BY id ASC`,
    )
      .bind(message.payload.workspaceId, message.payload.agentId)
      .all<{
        id: string;
        workspace_id: string;
        host_id: string;
        plugin_id: string;
        plugin_version_policy: string;
        name: string;
        roles_json: string;
        capabilities_json: string;
        config_json: string;
        secret_refs_json: string;
        billing_mode: string;
        cost_metadata_json: string;
        independence_key: string;
        concurrency_limit: number;
        session_policy: string;
        enabled: number;
      }>();
    const parseJson = (value: string, fallback: unknown): unknown => {
      try {
        return JSON.parse(value);
      } catch {
        return fallback;
      }
    };
    const desiredWorkers = (desiredWorkerRows.results ?? []).map((row) => ({
      workerId: row.id,
      workspaceId: row.workspace_id,
      agentId: row.host_id,
      workerCatalogId: row.plugin_id,
      workerVersionPolicy: row.plugin_version_policy,
      name: row.name,
      roles: parseJson(row.roles_json, []),
      capabilities: parseJson(row.capabilities_json, []),
      config: parseJson(row.config_json, {}),
      secretRefs: parseJson(row.secret_refs_json, []),
      enabled: row.enabled === 1,
      availability: "available",
      billingMode: row.billing_mode,
      costMetadata: parseJson(row.cost_metadata_json, {}),
      independenceKey: row.independence_key,
      concurrencyLimit: row.concurrency_limit,
      sessionPolicy: row.session_policy,
    }));
    const desiredPluginRows = await env.CONCLAVE_DB.prepare(
      `SELECT DISTINCT wp.id AS plugin_id, wp.publisher,
              wpv.version, wpv.protocol_version, wpv.min_agent_version,
              wpv.package_digest, wpv.package_r2_key, wpv.signature,
              wpv.permissions_json, wpv.supported_os_json, wpv.supported_arch_json,
              wpv.secret_schema_json
       FROM workers w
       JOIN worker_plugins wp ON wp.id = w.plugin_id AND wp.status = 'active'
       JOIN worker_plugin_versions wpv ON wpv.plugin_id = wp.id
         AND wpv.is_revoked = 0
         AND wpv.version = (
           SELECT latest.version
           FROM worker_plugin_versions latest
           WHERE latest.plugin_id = wp.id AND latest.is_revoked = 0
           ORDER BY latest.created_at DESC
           LIMIT 1
         )
       WHERE w.workspace_id = ?1 AND w.host_id = ?2 AND w.enabled = 1
       ORDER BY wp.id ASC`,
    )
      .bind(message.payload.workspaceId, message.payload.agentId)
      .all<{
        plugin_id: string;
        publisher: string;
        version: string;
        protocol_version: string;
        min_agent_version: string;
        package_digest: string;
        package_r2_key: string;
        signature: string;
        permissions_json: string;
        supported_os_json: string;
        supported_arch_json: string;
        secret_schema_json: string;
      }>();
    const desiredPlugins = (desiredPluginRows.results ?? []).map((row) => {
      const secretSchema = parseJson(row.secret_schema_json, {});
      const secretEnvironmentVariables = Array.isArray(secretSchema)
        ? secretSchema.filter(
            (name): name is string => typeof name === "string",
          )
        : typeof secretSchema === "object" && secretSchema !== null
          ? Object.keys(secretSchema)
          : [];
      return {
        workerCatalogId: row.plugin_id,
        publisher: row.publisher,
        version: row.version,
        protocolVersion: row.protocol_version,
        minAgentVersion: row.min_agent_version,
        packageDigest: row.package_digest,
        packageR2Key: row.package_r2_key,
        signature: row.signature,
        permissions: parseJson(row.permissions_json, []),
        supportedPlatforms: parseJson(row.supported_os_json, []),
        secretEnvironmentVariables,
      };
    });
    return json({
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: `msg-${Date.now()}`,
      correlationId: message.messageId,
      timestamp: now,
      type: "agent.sync.response",
      payload: {
        desiredPlugins,
        desiredWorkers,
        activeAssignmentIds: assignmentStates
          .filter(
            ({ status }) =>
              !["completed", "failed", "cancelled", "timed_out"].includes(
                status,
              ),
          )
          .map(({ assignmentId }) => assignmentId),
        assignmentStates,
      },
    });
  }

  if (message.type === "assignment.result") {
    if (
      authenticatedHost &&
      (authenticatedHost.id !== message.agentId ||
        authenticatedHost.workspace_id !== message.workspaceId)
    ) {
      return json(
        { error: "Host assignment identity mismatch" },
        { status: 403 },
      );
    }
    const assignment = await env.CONCLAVE_DB.prepare(
      `SELECT id FROM worker_assignments
       WHERE id = ?1 AND workspace_id = ?2 AND host_id = ?3 AND worker_id = ?4
         AND run_id = ?5 AND task_id = ?6 AND attempt_id = ?7
         AND idempotency_key = ?8`,
    )
      .bind(
        message.assignmentId,
        message.workspaceId,
        message.agentId,
        message.workerId,
        message.runId,
        message.taskId,
        message.attemptId,
        message.idempotencyKey,
      )
      .first<{ id: string }>();
    if (!assignment) {
      return json(
        { error: "Assignment correlation mismatch" },
        { status: 409 },
      );
    }
    await env.CONCLAVE_DB.prepare(
      `UPDATE worker_assignments SET status = 'completed', output_json = ?1, updated_at = ?2
       WHERE id = ?3 AND status NOT IN ('completed', 'failed', 'cancelled')`,
    )
      .bind(JSON.stringify(message.payload), now, message.assignmentId)
      .run();
    return json({ acknowledged: true });
  }

  if (message.type === "assignment.error") {
    if (
      authenticatedHost &&
      (authenticatedHost.id !== message.agentId ||
        authenticatedHost.workspace_id !== message.workspaceId)
    ) {
      return json(
        { error: "Host assignment identity mismatch" },
        { status: 403 },
      );
    }
    const assignment = await env.CONCLAVE_DB.prepare(
      `SELECT id FROM worker_assignments
       WHERE id = ?1 AND workspace_id = ?2 AND host_id = ?3 AND worker_id = ?4
         AND run_id = ?5 AND task_id = ?6 AND attempt_id = ?7
         AND idempotency_key = ?8`,
    )
      .bind(
        message.assignmentId,
        message.workspaceId,
        message.agentId,
        message.workerId,
        message.runId,
        message.taskId,
        message.attemptId,
        message.idempotencyKey,
      )
      .first<{ id: string }>();
    if (!assignment) {
      return json(
        { error: "Assignment correlation mismatch" },
        { status: 409 },
      );
    }
    await env.CONCLAVE_DB.prepare(
      `UPDATE worker_assignments SET status = 'failed', error_json = ?1, updated_at = ?2
       WHERE id = ?3 AND status NOT IN ('completed', 'failed', 'cancelled')`,
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
  const context = projectId
    ? await authorizeRequest(
        request,
        securityEnv,
        "project:read",
        projectId,
        accessContext,
      )
    : await securityContext(request, securityEnv, accessContext);
  if (context.authorizationModel === "v5") {
    // The snapshot endpoint is retained for older clients, but its previous
    // implementation queried the removed v4 Workspace-owned tables. V5/v6
    // clients use Project read models and explicit Workspace Grant endpoints;
    // this compatibility response only needs the user's Project list.
    const rows = await env.CONCLAVE_DB.prepare(
      `SELECT p.id, p.name, p.description,
              p.repository_id AS repository,
              p.settings_json AS settingsJson,
              p.updated_at AS lastActivity
       FROM projects p
       JOIN project_memberships pm ON pm.project_id = p.id
       WHERE pm.user_id = ?1
         AND COALESCE(json_extract(p.settings_json, '$.archived'), 0) = 0
       ORDER BY p.updated_at DESC`,
    )
      .bind(context.userId)
      .all<{
        id: string;
        name: string;
        description: string | null;
        repository: string | null;
        settingsJson: string | null;
        lastActivity: string;
      }>();
    const workstreamRows = await env.CONCLAVE_DB.prepare(
      `SELECT ws.id, ws.project_id AS projectId, ws.name, ws.status,
              ws.access_policy_json AS accessPolicyJson,
              ws.lead_user_id AS leadUserId,
              ws.created_at AS createdAt, ws.updated_at AS updatedAt
       FROM workstreams ws
       JOIN project_memberships pm ON pm.project_id = ws.project_id
       WHERE pm.user_id = ?1
       ORDER BY ws.created_at ASC`,
    )
      .bind(context.userId)
      .all<Record<string, unknown>>();
    const workstreamsByProject = new Map<string, Record<string, unknown>[]>();
    for (const row of workstreamRows.results ?? []) {
      const projectWorkstreams =
        workstreamsByProject.get(String(row.projectId)) ?? [];
      projectWorkstreams.push(workstreamMetadata(row));
      workstreamsByProject.set(String(row.projectId), projectWorkstreams);
    }
    return json({
      workspaceId: null,
      viewer: {
        id: context.userId,
        displayName: context.user.displayName,
        email: context.user.email,
      },
      activeRunId: null,
      run: null,
      projects: (rows.results ?? []).map((project) => {
        const settings = parseJson(project.settingsJson);
        const rawWorkstreams = workstreamsByProject.get(String(project.id)) ?? [];
        return {
          id: project.id,
          name: project.name,
          description: project.description,
          repository: project.repository ?? "",
          branch: "",
          activeGoals: 0,
          chats: [],
          workstreams: sortWorkstreams(rawWorkstreams, settings.workstreamOrder),
        };
      }),
      workers: [],
      hosts: [],
      plugins: [],
      tasks: [],
      findings: [],
      events: [],
      artifacts: [],
      modelCalls: [],
      accounts: [],
    });
  }
  if (!projectId && context.authorizedProjectIds.length === 0) {
    return json({
      workspaceId: null,
      viewer: {
        id: context.userId,
        displayName: context.user.displayName,
        email: context.user.email,
      },
      activeRunId: null,
      run: null,
      projects: [],
      workers: [],
      hosts: [],
      plugins: [],
      tasks: [],
      findings: [],
      events: [],
      artifacts: [],
      modelCalls: [],
      accounts: [],
    });
  }
  const testMode = testAuthenticationEnabled(securityEnv);
  const projectFilter =
    testMode
      ? ""
      : " WHERE p.workspace_id = ?1";
  const bind =
    testMode
      ? []
      : [context.workspaceId];
  const restrictProjects =
    !testMode &&
    context.workspaceRole !== "owner" &&
    context.workspaceRole !== "admin";
  const projectScope = (column: string, start: number): string => {
    if (!restrictProjects) return "";
    if (context.authorizedProjectIds.length === 0) return " AND 1 = 0";
    const placeholders = context.authorizedProjectIds
      .map((_, index) => `?${start + index}`)
      .join(",");
    return ` AND ${column} IN (${placeholders})`;
  };
  const projectListFilter =
    projectFilter + projectScope("p.id", bind.length + 1);
  const projectListBind = restrictProjects
    ? [...bind, ...context.authorizedProjectIds]
    : bind;
  const ownership =
    projectId === null
      ? testMode
        ? "1 = 1"
        : "p.workspace_id = ?1"
      : testMode
        ? "p.id = ?1"
        : "p.workspace_id = ?1 AND p.id = ?2";
  const ownershipBind = bind;
  const scopedOwnership =
    ownership + projectScope("p.id", ownershipBind.length + 1);
  const scopedOwnershipBind = restrictProjects
    ? [...ownershipBind, ...context.authorizedProjectIds]
    : ownershipBind;
  const [
    projects,
    workers,
    hosts,
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
      `SELECT p.id, p.name, COALESCE(p.repository_id, '') AS repository, '' AS branch, (SELECT COUNT(*) FROM goals g WHERE g.project_id = p.id AND g.status IN ('running', 'waiting')) AS activeGoals, p.updated_at AS lastActivity FROM projects p${projectListFilter} ORDER BY p.updated_at DESC`,
    )
      .bind(...projectListBind)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT w.id, w.name, w.host_id AS agentId, w.plugin_id AS workerCatalogId,
              w.plugin_version_policy AS workerVersionPolicy,
              w.roles_json, w.capabilities_json, w.config_json AS config,
              w.billing_mode AS billingMode, w.cost_metadata_json AS costMetadata,
              w.independence_key AS independenceKey, w.concurrency_limit AS concurrencyLimit,
              w.session_policy AS sessionPolicy, w.enabled, w.status, '' AS cost,
              COALESCE(a.name, 'Unassigned') AS agentName,
              COALESCE(wp.display_name, 'Unassigned') AS pluginName
       FROM workers w
       LEFT JOIN hosts a ON a.id = w.host_id
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
              (SELECT COUNT(*) FROM host_worker_installations i WHERE i.host_id = a.id) AS pluginCount,
              (SELECT COUNT(*) FROM workers w WHERE w.host_id = a.id) AS workerCount,
              (SELECT COUNT(*) FROM worker_assignments wa JOIN workers w ON w.id = wa.worker_id
               WHERE w.host_id = a.id AND wa.status IN ('assigned', 'running')) AS activeTaskCount
       FROM hosts a WHERE a.workspace_id = ?1 ORDER BY a.name`,
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
              (SELECT COUNT(DISTINCT i.host_id) FROM host_worker_installations i WHERE i.plugin_id = p.id AND i.status IN ('installed', 'active')) AS installedAgentCount,
              p.status, p.supported_roles_json AS roles, p.supported_capabilities_json AS capabilities
       FROM worker_plugins p
       WHERE p.status <> 'deprecated'
       GROUP BY p.id ORDER BY p.display_name`,
    ).all(),
    env.CONCLAVE_DB.prepare(
      `SELECT t.id, t.objective AS title, ph.name AS phase, t.status, t.role AS worker, t.objective AS detail, CASE WHEN t.status = 'completed' THEN 1 ELSE 0 END AS progress, '[]' AS dependencies, '—' AS tokens, '—' AS cost FROM tasks t JOIN phases ph ON ph.id = t.phase_id JOIN runs r ON r.id = ph.run_id JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE ${scopedOwnership} ORDER BY t.created_at DESC LIMIT 100`,
    )
      .bind(...scopedOwnershipBind)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT f.id, f.description AS title, f.description, f.severity, f.status, COALESCE(f.task_id, '') AS taskId, 'Unknown' AS author FROM findings f JOIN runs r ON r.id = f.run_id JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE ${scopedOwnership} ORDER BY f.created_at DESC LIMIT 100`,
    )
      .bind(...scopedOwnershipBind)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT e.occurred_at AS time, e.event_type AS title, e.entity_id AS detail, e.event_type AS kind, e.id AS eventId, e.correlation_id AS correlationId FROM events e JOIN runs r ON r.id = e.run_id JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE ${scopedOwnership} ORDER BY e.occurred_at DESC LIMIT 100`,
    )
      .bind(...scopedOwnershipBind)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT a.id AS name, a.media_type AS type, a.size_bytes AS size, 'Conclave' AS source FROM artifacts a JOIN runs r ON r.id = a.run_id JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE ${scopedOwnership} ORDER BY a.created_at DESC LIMIT 100`,
    )
      .bind(...scopedOwnershipBind)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT u.worker_id AS worker, u.model, u.provider, u.credential_profile_id AS credentialProfileId,
              u.credential_profile_owner_type AS credentialProfileOwnerType,
              u.credential_profile_owner_id AS credentialProfileOwnerId,
              u.requester_user_id AS requesterUserId, u.host_id AS hostId,
              u.billing_category AS billingCategory,
              u.run_id AS task, (u.input_tokens + u.output_tokens) AS tokens,
              u.cost_micros AS cost, u.duration_ms AS duration,
              'recorded' AS status
       FROM usage u
       JOIN runs r ON r.id = u.run_id
       JOIN goals g ON g.id = r.goal_id
       JOIN projects p ON p.id = g.project_id
       WHERE ${scopedOwnership} ORDER BY u.recorded_at DESC LIMIT 100`,
    )
      .bind(...scopedOwnershipBind)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT r.id FROM runs r JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE ${scopedOwnership} AND r.status IN ('active', 'running', 'waiting') ORDER BY r.created_at DESC LIMIT 1`,
    )
      .bind(...scopedOwnershipBind)
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
       FROM runs r JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE ${scopedOwnership} ORDER BY r.created_at DESC LIMIT 1`,
    )
      .bind(...scopedOwnershipBind)
      .first(),
  ]);
  const chatFilter =
    projectId === null
      ? testMode
        ? "1 = 1"
        : "c.workspace_id = ?1"
      : testMode
        ? "c.project_id = ?1"
        : "c.workspace_id = ?1 AND c.project_id = ?2";
  const chatBind =
    projectId === null
      ? testMode
        ? []
        : [context.workspaceId]
      : testMode
        ? [projectId]
        : [context.workspaceId, projectId];
  const scopedChatFilter =
    chatFilter + projectScope("c.project_id", chatBind.length + 1);
  const scopedChatBind = restrictProjects
    ? [...chatBind, ...context.authorizedProjectIds]
    : chatBind;
  const [chats, chatMessages] = await Promise.all([
    env.CONCLAVE_DB.prepare(
      `SELECT c.id, c.project_id AS projectId, c.workspace_id AS workspaceId,
              c.created_by_user_id AS createdByUserId, c.title, c.status,
              c.created_at AS createdAt, c.updated_at AS updatedAt
       FROM chats c WHERE ${scopedChatFilter} ORDER BY c.updated_at DESC`,
    )
      .bind(...scopedChatBind)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT m.id, m.chat_id AS chatId, m.sender_type AS senderType,
              m.content, m.kind, m.goal_id AS goalId, m.metadata_json AS metadata,
              m.created_at AS createdAt
       FROM chat_messages m
       JOIN chats c ON c.id = m.chat_id
       WHERE ${scopedChatFilter}
       ORDER BY m.created_at ASC`,
    )
      .bind(...scopedChatBind)
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
  const accountRows = await env.CONCLAVE_DB.prepare(
    `SELECT id FROM credential_profiles
     WHERE workspace_id = ?1 AND status <> 'revoked'
     ORDER BY display_name`,
  )
    .bind(context.workspaceId)
    .all<{ id: string }>();
  const accounts = [];
  for (const row of accountRows.results ?? []) {
    const profile = await loadCredentialProfile(
      env,
      context.workspaceId,
      row.id,
    );
    if (!profile) continue;
    try {
      await authorizeCredentialProfileUse(env.CONCLAVE_DB, context, row.id);
      accounts.push(accountMetadata(profile));
    } catch {
      // Snapshot Account data is requester-specific and metadata-only.
    }
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
      config: mapObject(row.config),
      costMetadata: mapObject(row.costMetadata),
      status: row.status ?? "unknown",
    })),
    hosts: hosts.results ?? [],
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
    accounts,
  });
}

/**
 * Project-scoped read model used by the web App. Keep this response limited to
 * the active project so a large Workspace does not turn every refresh into a
 * full application snapshot.
 */
async function handleProjectReadModel(
  env: Env,
  request: Request,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const securityEnv = env as SecurityEnv;
  const context = await authorizeRequest(
    request,
    securityEnv,
    "project:read",
    projectId,
    accessContext,
  );
  const projectRow = await env.CONCLAVE_DB.prepare(
    `SELECT p.id, p.workspace_id AS workspaceId, p.name,
            COALESCE(p.repository_id, '') AS repository,
            p.description, p.settings_json AS settings,
            p.created_at AS createdAt, p.updated_at AS updatedAt
     FROM projects p
     WHERE p.id = ?1 AND p.workspace_id = ?2`,
  )
    .bind(projectId, context.workspaceId)
    .first<{
      id: string;
      workspaceId: string;
      name: string;
      repository: string;
      description: string | null;
      settings: string;
      createdAt: string;
      updatedAt: string;
    }>();
  if (!projectRow) throw new HttpError(404, "Project not found");

  const chats = await env.CONCLAVE_DB.prepare(
    `SELECT c.id, c.project_id AS projectId, c.workspace_id AS workspaceId,
            c.created_by_user_id AS createdByUserId, c.title, c.status,
            c.created_at AS createdAt, c.updated_at AS updatedAt
     FROM chats c WHERE c.project_id = ?1 AND c.workspace_id = ?2
     ORDER BY c.updated_at DESC`,
  )
    .bind(projectId, context.workspaceId)
    .all<Record<string, unknown>>();
  const messages = await env.CONCLAVE_DB.prepare(
    `SELECT m.id, m.chat_id AS chatId, m.sender_type AS senderType,
            m.content, m.kind, m.goal_id AS goalId,
            m.metadata_json AS metadata, m.created_at AS createdAt
     FROM chat_messages m JOIN chats c ON c.id = m.chat_id
     WHERE c.project_id = ?1 AND c.workspace_id = ?2
     ORDER BY m.created_at ASC`,
  )
    .bind(projectId, context.workspaceId)
    .all<Record<string, unknown>>();
  const messagesByChat = new Map<string, Record<string, unknown>[]>();
  for (const row of messages.results ?? []) {
    const metadata = parseJson<Record<string, unknown>>(row.metadata);
    const chatMessages = messagesByChat.get(String(row.chatId)) ?? [];
    chatMessages.push({
      id: row.id,
      sender:
        row.senderType === "user"
          ? "user"
          : row.senderType === "system"
            ? "system"
            : "conclave",
      text: row.content,
      timestamp: row.createdAt,
      ...(metadata.runPreview ? { runPreview: metadata.runPreview } : {}),
    });
    messagesByChat.set(String(row.chatId), chatMessages);
  }
  const project = {
    ...projectRow,
    settings: parseJson(projectRow.settings),
    chats: (chats.results ?? []).map((chat) => ({
      ...chat,
      lastActivity: chat.updatedAt,
      messages: messagesByChat.get(String(chat.id)) ?? [],
    })),
  };
  const latestRun = await env.CONCLAVE_DB.prepare(
    `SELECT r.id, r.status, g.objective, r.created_at AS createdAt,
            r.started_at AS startedAt, r.finished_at AS finishedAt
     FROM runs r JOIN goals g ON g.id = r.goal_id
     WHERE r.project_id = ?1 AND r.workspace_id = ?2
     ORDER BY r.created_at DESC LIMIT 1`,
  )
    .bind(projectId, context.workspaceId)
    .first<Record<string, unknown>>();
  return json({
    workspaceId: context.workspaceId,
    project,
    run: latestRun ?? null,
    activeRunId:
      latestRun &&
      ["created", "running", "paused"].includes(String(latestRun.status))
        ? latestRun.id
        : null,
    tasks: [],
    findings: [],
    events: [],
    artifacts: [],
    modelCalls: [],
  });
}

async function handleWorkspaceUsage(
  request: Request,
  env: SecurityEnv,
  workspaceId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const context = await securityContext(request, env, accessContext);
  authorize(context, "project:read");
  await requireWorkspaceContext(context, env, workspaceId);
  const search = new URL(request.url).searchParams;
  const urlSearch = (name: string) => search.get(name) ?? "";
  const allowedRanges = new Set(["7d", "30d"]);
  const range = allowedRanges.has(urlSearch("range"))
    ? urlSearch("range")
    : "30d";
  const projectId = urlSearch("projectId");
  const requesterUserId = urlSearch("requesterUserId");
  const credentialProfileId = urlSearch("credentialProfileId");
  const workerId = urlSearch("workerId");
  const provider = urlSearch("provider");
  const model = urlSearch("model");
  const from = urlSearch("from");
  const to = urlSearch("to");
  const conditions = ["u.workspace_id = ?"];
  const bindings: unknown[] = [workspaceId];
  if (from) {
    conditions.push("u.recorded_at >= ?");
    bindings.push(from);
  } else {
    conditions.push("u.recorded_at >= datetime('now', ?)");
    bindings.push(range === "7d" ? "-7 days" : "-30 days");
  }
  if (to) {
    conditions.push("u.recorded_at <= ?");
    bindings.push(to);
  }
  for (const [value, sql] of [
    [projectId, "u.project_id = ?"],
    [requesterUserId, "u.requester_user_id = ?"],
    [credentialProfileId, "u.credential_profile_id = ?"],
    [workerId, "u.worker_id = ?"],
    [provider, "u.provider = ?"],
    [model, "u.model = ?"],
  ] as const) {
    if (value) {
      conditions.push(sql);
      bindings.push(value);
    }
  }
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT u.id, u.project_id AS projectId, p.name AS projectName,
            u.run_id AS runId, u.requester_user_id AS requesterUserId,
            requester.display_name AS requesterName,
            u.credential_profile_id AS credentialProfileId,
            cp.display_name AS accountName,
            cp.owner_type AS accountOwnerType,
            cp.owner_id AS accountOwnerId,
            CASE WHEN cp.owner_type = 'user' THEN owner.display_name
                 WHEN cp.owner_type = 'workspace' THEN w.name ELSE NULL END
              AS accountOwnerName,
            u.worker_id AS workerId, worker.display_name AS workerName,
            u.host_id AS hostId, u.provider, u.model,
            u.billing_category AS billingCategory,
            u.input_tokens AS inputTokens, u.output_tokens AS outputTokens,
            (u.input_tokens + u.output_tokens) AS tokens,
            u.cost_micros AS costMicros, u.duration_ms AS durationMs,
            u.recorded_at AS recordedAt
       FROM usage u
       JOIN projects p ON p.id = u.project_id
       JOIN workers worker ON worker.id = u.worker_id
       LEFT JOIN users requester ON requester.id = u.requester_user_id
       LEFT JOIN credential_profiles cp ON cp.id = u.credential_profile_id
       LEFT JOIN users owner ON cp.owner_type = 'user' AND owner.id = cp.owner_id
       LEFT JOIN workspaces w ON cp.owner_type = 'workspace' AND w.id = cp.owner_id
      WHERE ${conditions.join(" AND ")}
      ORDER BY u.recorded_at DESC
      LIMIT 1000`,
  )
    .bind(...bindings)
    .all();
  const usage = rows.results ?? [];
  const number = (value: unknown) =>
    typeof value === "number" ? value : Number(value ?? 0);
  const summary = usage.reduce<{
    tokens: number;
    knownApiCostMicros: number;
    subscriptionUsage: number;
    durationMs: number;
    runs: Set<string>;
  }>(
    (result, row) => {
      const item = row as Record<string, unknown>;
      result.tokens += number(item.tokens);
      result.durationMs += number(item.durationMs);
      result.runs.add(String(item.runId));
      if (item.billingCategory === "api" && item.costMicros != null) {
        result.knownApiCostMicros += number(item.costMicros);
      }
      if (item.billingCategory === "subscription") result.subscriptionUsage++;
      return result;
    },
    {
      tokens: 0,
      knownApiCostMicros: 0,
      subscriptionUsage: 0,
      durationMs: 0,
      runs: new Set<string>(),
    },
  );
  return json({
    range,
    filters: {
      projectId,
      requesterUserId,
      credentialProfileId,
      workerId,
      provider,
      model,
      from,
      to,
    },
    summary: {
      tokens: summary.tokens,
      knownApiCostMicros: summary.knownApiCostMicros,
      subscriptionUsage: summary.subscriptionUsage,
      runs: summary.runs.size,
      durationMs: summary.durationMs,
    },
    usage,
  });
}

async function handleProjectUsage(
  request: Request,
  env: SecurityEnv,
  projectId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(
    request,
    env,
    "project:read",
    projectId,
    accessContext,
  );
  const search = new URL(request.url).searchParams;
  const from = search.get("from") ?? "";
  const to = search.get("to") ?? "";
  const conditions = ["u.project_id = ?1"];
  const bindings: unknown[] = [projectId];
  if (from) {
    conditions.push("u.recorded_at >= ?" + (bindings.length + 1));
    bindings.push(from);
  }
  if (to) {
    conditions.push("u.recorded_at <= ?" + (bindings.length + 1));
    bindings.push(to);
  }
  const rows = await env.CONCLAVE_DB.prepare(
    `SELECT u.id, u.project_id AS projectId, u.run_id AS runId,
            u.requester_user_id AS requesterUserId, requester.display_name AS requesterName,
            u.execution_workspace_id AS executionWorkspaceId, ew.name AS executionWorkspaceName,
            u.workspace_owner_user_id AS workspaceOwnerUserId, workspaceOwner.display_name AS workspaceOwnerName,
            u.worker_id AS workerId, worker.name AS workerName,
            u.account_id AS accountId, u.account_owner_user_id AS accountOwnerUserId,
            accountOwner.display_name AS accountOwnerName,
            u.provider, u.model, u.billing_category AS billingCategory,
            u.input_tokens AS inputTokens, u.output_tokens AS outputTokens,
            (u.input_tokens + u.output_tokens) AS tokens,
            u.cost_micros AS costMicros, u.duration_ms AS durationMs, u.recorded_at AS recordedAt
       FROM usage u
       JOIN execution_workspaces ew ON ew.id = u.execution_workspace_id
       JOIN workers worker ON worker.id = u.worker_id
       LEFT JOIN users requester ON requester.id = u.requester_user_id
       LEFT JOIN users workspaceOwner ON workspaceOwner.id = u.workspace_owner_user_id
       LEFT JOIN users accountOwner ON accountOwner.id = u.account_owner_user_id
      WHERE ${conditions.join(" AND ")}
      ORDER BY u.recorded_at DESC LIMIT 1000`,
  )
    .bind(...bindings)
    .all<Record<string, unknown>>();
  const usage = rows.results ?? [];
  const total = (key: string) =>
    usage.reduce((sum, row) => sum + Number(row[key] ?? 0), 0);
  const budgets = await env.CONCLAVE_DB.prepare(
    `SELECT id, run_id AS runId, account_id AS accountId,
            max_input_tokens AS maxInputTokens, max_output_tokens AS maxOutputTokens,
            max_cost_micros AS maxCostMicros, used_input_tokens AS usedInputTokens,
            used_output_tokens AS usedOutputTokens, used_cost_micros AS usedCostMicros, status
       FROM budgets WHERE project_id = ?1 ORDER BY created_at DESC`,
  )
    .bind(projectId)
    .all<Record<string, unknown>>();
  return json({
    projectId,
    filters: { from, to },
    summary: {
      tokens: total("tokens"),
      inputTokens: total("inputTokens"),
      outputTokens: total("outputTokens"),
      costMicros: total("costMicros"),
      durationMs: total("durationMs"),
      runs: new Set(usage.map((row) => String(row.runId))).size,
    },
    usage,
    budgets: budgets.results ?? [],
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
    const projectId = testAuthenticationEnabled(securityEnv)
      ? undefined
      : await runProjectId(securityEnv, runId);
    controlContext = await authorizeRequest(
      request,
      securityEnv,
      "run.control",
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
  workerCatalogId: string,
): Promise<Response> {
  const plugin = await env.CONCLAVE_DB.prepare(
    "SELECT * FROM worker_plugins WHERE id = ?1",
  )
    .bind(workerCatalogId)
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
    return json(
      { error: `Plugin '${workerCatalogId}' not found` },
      { status: 404 },
    );
  }

  const versionsResult = await env.CONCLAVE_DB.prepare(
    "SELECT * FROM worker_plugin_versions WHERE plugin_id = ?1 ORDER BY created_at DESC",
  )
    .bind(workerCatalogId)
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
  workerCatalogId: string,
  version: string,
): Promise<Response> {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT * FROM worker_plugin_versions WHERE plugin_id = ?1 AND version = ?2",
  )
    .bind(workerCatalogId, version)
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
      { error: `Plugin version '${workerCatalogId}@${version}' not found` },
      { status: 404 },
    );
  }

  return json({
    id: row.id,
    workerCatalogId: row.plugin_id,
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
  workerCatalogId: string,
  version: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  if (!testAuthenticationEnabled(env)) {
    const token = extractBearerToken(request.headers);
    if (token) {
      const tokenHash = await hashToken(token);
      const agent = await env.CONCLAVE_DB.prepare(
        `SELECT a.id, a.workspace_id
         FROM hosts a
         JOIN workers w ON w.host_id = a.id AND w.workspace_id = a.workspace_id
         WHERE a.auth_token_hash = ?1
           AND a.revoked_at IS NULL
           AND w.plugin_id = ?2
           AND w.enabled = 1
         LIMIT 1`,
      )
        .bind(tokenHash, workerCatalogId)
        .first<{ id: string; workspace_id: string }>();
      if (!agent) {
        return json(
          { error: "Agent is not authorized to download this plugin" },
          { status: 403 },
        );
      }
    } else {
      await authorizeRequest(request, env, "worker.install", undefined, ctx);
    }
  }
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT package_r2_key, package_digest, is_revoked FROM worker_plugin_versions WHERE plugin_id = ?1 AND version = ?2",
  )
    .bind(workerCatalogId, version)
    .first<{
      package_r2_key: string;
      package_digest: string;
      is_revoked: number;
    }>();

  if (!row) {
    return json(
      { error: `Plugin version '${workerCatalogId}@${version}' not found` },
      { status: 404 },
    );
  }

  if (row.is_revoked === 1) {
    return json(
      {
        error: `Plugin version '${workerCatalogId}@${version}' is revoked and cannot be downloaded`,
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
    `attachment; filename="${workerCatalogId}-${version}.tgz"`,
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

  const manifest = validateWorkerManifest(body.manifest);
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

  const workerIdentifier = manifest.workerId || "unknown";
  const minimumAgentVersion = manifest.minimumHostVersion || "0.1.0";

  const r2Key = `plugins/${workerIdentifier}/${manifest.version}/${digest.replace(/^sha256:/, "")}.tgz`;
  const bucket =
    (env as unknown as { CONCLAVE_PLUGINS?: R2Bucket }).CONCLAVE_PLUGINS ??
    env.CONCLAVE_ARTIFACTS;
  if (bucket) {
    await bucket.put(r2Key, packageBytes, {
      httpMetadata: { contentType: "application/gzip" },
      customMetadata: {
        workerCatalogId: workerIdentifier,
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
      workerIdentifier,
      manifest.displayName,
      manifest.description ?? "",
      manifest.publisher,
      JSON.stringify(manifest.roles),
      JSON.stringify(manifest.capabilities),
      now,
    )
    .run();

  // 2. Upsert worker_plugin_versions
  const versionId = `ver-${workerIdentifier}-${manifest.version}`;
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
      workerIdentifier,
      manifest.version,
      channel,
      manifest.protocolVersion ?? "4.0",
      minimumAgentVersion,
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
    workerCatalogId: workerIdentifier,
    workerId: workerIdentifier,
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
  workerCatalogId: string,
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
    .bind(now, reason, workerCatalogId, version)
    .run();

  return json({
    workerCatalogId,
    version,
    isRevoked: true,
    revokedAt: now,
    revocationReason: reason,
  });
}

async function handleDeprecatePlugin(
  request: Request,
  env: SecurityEnv,
  workerCatalogId: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  await authorizeRequest(request, env, "workspace:manage", undefined, ctx);

  const now = new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    `UPDATE worker_plugins SET status = 'deprecated', updated_at = ?1 WHERE id = ?2`,
  )
    .bind(now, workerCatalogId)
    .run();

  return json({
    workerCatalogId,
    status: "deprecated",
    updatedAt: now,
  });
}

// =========================================================================
// Agent Releases API Handlers (Architecture v2 Self-Update)
// =========================================================================

async function handleGetLatestHostRelease(
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
     FROM host_releases
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
      // Agent releases use the Cloud-managed signing identity. Keep the
      // publisher explicit so Agents can apply their trust policy rather than
      // treating a missing publisher as an unsigned release.
      publisher: "conclave",
      signature: latest.signature,
      releaseNotes: latest.releaseNotes,
      createdAt: latest.createdAt,
    },
  });
}

async function handleGetHostRelease(
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
     FROM host_releases WHERE version = ?1`,
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

async function handleDownloadHostRelease(
  request: Request,
  env: SecurityEnv,
  version: string,
  ctx?: ExecutionContext,
): Promise<Response> {
  if (!testAuthenticationEnabled(env)) {
    const token = extractBearerToken(request.headers);
    if (token) {
      const tokenHash = await hashToken(token);
      const agent = await env.CONCLAVE_DB.prepare(
        `SELECT id FROM hosts
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
      await authorizeRequest(request, env, "host.view", undefined, ctx);
    }
  }
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT package_r2_key, package_digest, is_revoked, revocation_reason FROM host_releases WHERE version = ?1`,
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

async function handlePublishHostRelease(
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
    env.CONCLAVE_HOST_SIGNING_KEY ||
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
    `INSERT INTO host_releases (
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

async function handleRevokeHostRelease(
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
    `UPDATE host_releases
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

export {
  json,
  errorMessage,
  HttpError,
  testAuthenticationEnabled,
  runProjectId,
  authorizeRequest,
  resolveWorkflowInstanceId,
  handleSession,
  handleSessionLogout,
  handleCompleteStepUp,
  handleListPendingInvitations,
  handleConnectorTaskRequest,
  handleListWorkspaces,
  handleCreateWorkspace,
  handleUploadArtifact,
  handleGetArtifact,
  handleExportWorkspaceAudit,
  handleCreateWorkspaceBackup,
  handleVerifyWorkspaceBackup,
  handleListWorkspaceInvitations,
  handleCreateWorkspaceInvitation,
  handleExpireWorkspaceInvitation,
  handleAcceptWorkspaceInvitation,
  handleChangeWorkspaceMemberRole,
  handleWorkspaceMemberStatus,
  handleInternalDispatchTaskAssignment,
  handleWorkspaceGatewayConnect,
  handleEnrollHost,
  handleBindHostWorkspace,
  handleListHostEnrollments,
  handleCreateHostEnrollment,
  handleRevokeHostEnrollment,
  handleListHosts,
  handleGetHost,
  handleRevokeHost,
  handleUpdateHost,
  handleAnnounceHostUpdate,
  handleSetHostDesiredState,
  handleListCredentialProfiles,
  handleCreateCredentialProfile,
  handleUpdateCredentialProfile,
  handleRevokeCredentialProfile,
  handleCreateCredentialSetupIntent,
  handleCreateCredentialGrant,
  handleRevokeCredentialGrant,
  handleDispatchEnsembleTaskAssignment,
  handleDispatchTaskAssignment,
  handleCancelTaskAssignment,
  handleListPlugins,
  handlePublishPlugin,
  handleDownloadPluginVersion,
  handleRevokePluginVersion,
  handleGetPluginVersion,
  handleDeprecatePlugin,
  handleGetPlugin,
  handleGetLatestHostRelease,
  handlePublishHostRelease,
  handleDownloadHostRelease,
  handleRevokeHostRelease,
  handleGetHostRelease,
  handleGetWorkspace,
  handleUpdateWorkspace,
  handleListWorkspaceMembers,
  handleListProjects,
  handleCreateProject,
  handleUpdateProject,
  handleDeleteProject,
  handleListProjectMembers,
  handleListProjectInvitations,
  handleListProjectAudit,
  handleCreateProjectInvitation,
  handleChangeProjectMemberRole,
  handleRemoveProjectMember,
  handleExpireProjectInvitation,
  handleAcceptProjectInvitation,
  handleListChats,
  handleCreateChat,
  handleGetProject,
  handleListChatGoals,
  handleListChatMessages,
  handleCreateChatMessage,
  handleListDiscussionMessages,
  handleCreateDiscussionMessage,
  handleEditDiscussionMessage,
  handleCreateWorkRequest,
  handleCancelWorkRequest,
  handleGetChat,
  handleUpdateChat,
  handleRunRequest,
  handleGoalRequest,
  handleStudioSnapshot,
  handleProjectReadModel,
  handleProjectUsage,
  handleWorkspaceUsage,
  handleRunCommand,
};
