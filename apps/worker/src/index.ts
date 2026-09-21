export { ConclaveRunWorkflow } from "./workflow.js";
export { RuntimeConnection } from "./runtime-connection.js";
import {
  authorize,
  type Permission,
  type Role,
  type SecurityContext,
} from "@conclave/security";
import { parseMachineCheckEvidence } from "@conclave/protocol";

function json(data: unknown, init?: ResponseInit): Response {
  return Response.json(data, {
    ...init,
    headers: {
      "content-type": "application/json; charset=utf-8",
      ...init?.headers,
    },
  });
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

interface WorkflowExecutionRow {
  readonly workflow_instance_id: string;
}

async function resolveWorkflowInstanceId(
  env: Env,
  runId: string,
  idempotencyKey?: string,
): Promise<string> {
  const existing = await env.CONCLAVE_DB.prepare(
    "SELECT workflow_instance_id FROM run_external_executions WHERE run_id = ?1 AND execution_type = 'cloudflare_workflow'",
  )
    .bind(runId)
    .first<WorkflowExecutionRow>();
  if (existing) return existing.workflow_instance_id;
  if (!idempotencyKey)
    throw new HttpError(404, "Run workflow execution not found");
  const candidate = workflowInstanceId(idempotencyKey);
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO run_external_executions (run_id, execution_type, workflow_instance_id, external_run_id, status, created_at, updated_at)
     VALUES (?1, 'cloudflare_workflow', ?2, NULL, 'created', ?3, ?3)
     ON CONFLICT(run_id, execution_type) DO NOTHING`,
  )
    .bind(runId, candidate, new Date().toISOString())
    .run();
  const persisted = await env.CONCLAVE_DB.prepare(
    "SELECT workflow_instance_id FROM run_external_executions WHERE run_id = ?1 AND execution_type = 'cloudflare_workflow'",
  )
    .bind(runId)
    .first<WorkflowExecutionRow>();
  if (!persisted)
    throw new Error("Run workflow execution mapping was not persisted");
  return persisted.workflow_instance_id;
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
  readonly CONCLAVE_AUTH_USER_ID?: string;
  readonly CONCLAVE_AUTH_ORGANIZATION_ID?: string;
  readonly CONCLAVE_ALLOW_ANONYMOUS_DEV?: string;
  readonly CONCLAVE_CI_INGEST_TOKEN?: string;
  readonly CONCLAVE_FORGE_CALLBACK_TOKEN?: string;
  readonly CONCLAVE_RUNTIME_CONNECT_TOKEN?: string;
  readonly CONCLAVE_RUNTIME_OPERATION_TOKEN?: string;
  readonly CONCLAVE_RUNTIME_CONNECTION: DurableObjectNamespace;
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

async function accessSecurityContext(
  env: SecurityEnv,
  accessContext: ExecutionContext | undefined,
): Promise<SecurityContext> {
  const identity = await accessContext?.access?.getIdentity();
  const userId = identity?.email?.trim().toLowerCase();
  if (!userId)
    throw new HttpError(401, "Cloudflare Access authentication required");

  const organizationQuery = env.CONCLAVE_ACCESS_ORGANIZATION_ID
    ? "SELECT organization_id, role, status FROM organization_memberships WHERE organization_id = ?1 AND user_id = ?2"
    : "SELECT organization_id, role, status FROM organization_memberships WHERE user_id = ?1";
  const membershipStatement = env.CONCLAVE_DB.prepare(organizationQuery);
  const memberships = env.CONCLAVE_ACCESS_ORGANIZATION_ID
    ? await membershipStatement
        .bind(env.CONCLAVE_ACCESS_ORGANIZATION_ID, userId)
        .all<{ organization_id: string; role: string; status: string }>()
    : await membershipStatement
        .bind(userId)
        .all<{ organization_id: string; role: string; status: string }>();
  const activeMemberships = (memberships.results ?? []).filter(
    (membership) => membership.status === "active",
  );
  if (activeMemberships.length !== 1)
    throw new HttpError(
      activeMemberships.length === 0 ? 403 : 409,
      activeMemberships.length === 0
        ? "Organization membership is not active"
        : "An organization must be selected for this identity",
    );
  const membership = activeMemberships[0]!;
  const projects = await env.CONCLAVE_DB.prepare(
    "SELECT project_id, role FROM project_memberships WHERE project_id IN (SELECT id FROM projects WHERE organization_id = ?1) AND user_id = ?2",
  )
    .bind(membership.organization_id, userId)
    .all<{ project_id: string; role: string }>();
  const projectRoles: Record<string, readonly Role[]> = {};
  for (const project of projects.results ?? [])
    projectRoles[project.project_id] = [project.role as Role];
  return {
    userId,
    organizationId: membership.organization_id,
    organizationRoles: [membership.role as Role],
    projectRoles,
  };
}

async function securityContext(
  request: Request,
  env: SecurityEnv,
  accessContext?: ExecutionContext,
): Promise<SecurityContext> {
  if (anonymousDevelopment(env)) {
    return {
      userId: "local-development",
      organizationId: "local-development",
      organizationRoles: ["owner"],
      projectRoles: {},
    };
  }
  if (env.CONCLAVE_ENVIRONMENT === "development" && env.CONCLAVE_AUTH_TOKEN) {
    const token = bearer(request);
    if (!token || token !== env.CONCLAVE_AUTH_TOKEN)
      throw new HttpError(401, "Authentication required");
    const userId = env.CONCLAVE_AUTH_USER_ID;
    const organizationId = env.CONCLAVE_AUTH_ORGANIZATION_ID;
    if (!userId || !organizationId)
      throw new HttpError(503, "Authentication is not configured");
    const membership = await env.CONCLAVE_DB.prepare(
      "SELECT role, status FROM organization_memberships WHERE organization_id = ?1 AND user_id = ?2",
    )
      .bind(organizationId, userId)
      .first<{ role: string; status: string }>();
    if (!membership || membership.status !== "active")
      throw new HttpError(403, "Organization membership is not active");
    return {
      userId,
      organizationId,
      organizationRoles: [membership.role as Role],
      projectRoles: {},
    };
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
      "SELECT organization_id FROM projects WHERE id = ?1",
    )
      .bind(projectId)
      .first<{ organization_id: string | null }>();
    if (!project || project.organization_id !== context.organizationId)
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
    projectId,
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
      `INSERT INTO goals (id, project_id, original_message, objective, constraints_json, completion_criteria_json, verification_policy_json, status, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)`,
    ).bind(
      goal.id,
      goal.projectId,
      goal.originalMessage,
      goal.objective,
      JSON.stringify(goal.constraints),
      JSON.stringify(goal.completionCriteria),
      JSON.stringify(goal.verificationPolicy),
      goal.status,
      now,
      now,
    ),
    env.CONCLAVE_DB.prepare(
      `INSERT INTO runs (id, goal_id, policy_snapshot_json, status, started_at, created_at, updated_at)
         VALUES (?1, ?2, ?3, 'running', ?4, ?4, ?4)`,
    ).bind(runId, goalId, JSON.stringify(goal.verificationPolicy), now),
    ...criterionRows.map((criterion) =>
      env.CONCLAVE_DB.prepare(
        `INSERT INTO completion_criteria (id, goal_id, description, verification_requirement, status, evidence_artifact_ids_json, created_at, updated_at)
           VALUES (?1, ?2, ?3, 'independent verification', 'pending', '[]', ?4, ?4)`,
      ).bind(criterion.id, goalId, criterion.description, now),
    ),
  ];
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
  return json({ goalId, runId, ...run }, { status: 202 });
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
        : " WHERE p.organization_id = ?1"
      : isAnonymous
        ? " WHERE p.id = ?1"
        : " WHERE p.id = ?2 AND p.organization_id = ?1";
  const bind =
    projectId === null
      ? isAnonymous
        ? []
        : [context.organizationId]
      : isAnonymous
        ? [projectId]
        : [context.organizationId, projectId];
  const ownership =
    projectId === null
      ? isAnonymous
        ? "1 = 1"
        : "p.organization_id = ?1"
      : isAnonymous
        ? "p.id = ?1"
        : "p.organization_id = ?1 AND p.id = ?2";
  const ownershipBind = bind;
  const [
    projects,
    workers,
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
      "SELECT id, name, provider, roles_json, capabilities_json, availability AS status, '' AS cost FROM workers WHERE organization_id = ?1 ORDER BY name",
    )
      .bind(context.organizationId)
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
      `SELECT e.occurred_at AS time, e.event_type AS title, e.entity_id AS detail, e.event_type AS kind FROM run_events e JOIN runs r ON r.id = e.run_id JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE ${ownership} ORDER BY e.occurred_at DESC LIMIT 100`,
    )
      .bind(...ownershipBind)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT a.id AS name, a.media_type AS type, a.size_bytes AS size, 'Conclave' AS source FROM artifacts a JOIN runs r ON r.id = a.run_id JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE ${ownership} ORDER BY a.created_at DESC LIMIT 100`,
    )
      .bind(...ownershipBind)
      .all(),
    env.CONCLAVE_DB.prepare(
      `SELECT mc.worker_id AS worker, mc.model, mc.attempt_id AS task, u.input_tokens + u.output_tokens AS tokens, u.estimated_cost_micros AS cost, '—' AS duration, mc.status FROM model_calls mc JOIN attempts a ON a.id = mc.attempt_id JOIN tasks t ON t.id = a.task_id JOIN phases ph ON ph.id = t.phase_id JOIN runs r ON r.id = ph.run_id JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id LEFT JOIN usage u ON u.attempt_id = a.id WHERE ${ownership} ORDER BY mc.started_at DESC LIMIT 100`,
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
        COALESCE((SELECT SUM(estimated_cost_micros) FROM usage u WHERE u.run_id = r.id), 0) AS costMicros
       FROM runs r JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id WHERE ${ownership} ORDER BY r.created_at DESC LIMIT 1`,
    )
      .bind(...ownershipBind)
      .first(),
  ]);
  const mapJson = (value: unknown): string[] =>
    typeof value === "string" ? (JSON.parse(value) as string[]) : [];
  return json({
    activeRunId: activeRun?.id ?? null,
    run: latestRun ?? null,
    projects: projects.results ?? [],
    workers: (workers.results ?? []).map((row) => ({
      ...row,
      role: mapJson(row.roles_json)[0] ?? "worker",
      capabilities: mapJson(row.capabilities_json),
      status: row.status ?? "unknown",
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
    `SELECT r.policy_snapshot_json, p.repository_id, p.organization_id
     FROM runs r JOIN goals g ON g.id = r.goal_id JOIN projects p ON p.id = g.project_id
     WHERE r.id = ?1`,
  )
    .bind(runId)
    .first<{
      policy_snapshot_json: string;
      repository_id: string | null;
      organization_id: string | null;
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
  if (!expected.organization_id)
    throw new HttpError(409, "Run has no organization correlation");
  try {
    await env.CONCLAVE_DB.prepare(
      `INSERT INTO run_ci_evidence
       (evidence_id, run_id, organization_id, repository_id, commit_sha, workflow, external_run_id, status, claimed_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'claimed', ?8)`,
    )
      .bind(
        evidence.evidenceId,
        runId,
        expected.organization_id,
        evidence.repositoryId,
        evidence.commitSha,
        evidence.workflow,
        evidence.externalRunId,
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
  if (command === "ci-evidence") requireCiAuthentication(request, securityEnv);
  if (command === "forge-terminal") {
    requireForgeCallbackAuthentication(request, securityEnv);
  } else {
    const projectId = anonymousDevelopment(securityEnv)
      ? undefined
      : await runProjectId(securityEnv, runId);
    await authorizeRequest(
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
        "UPDATE run_ci_evidence SET status = 'consumed', consumed_at = ?1 WHERE evidence_id = ?2 AND status = 'claimed'",
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
