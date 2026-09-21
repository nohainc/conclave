export { ConclaveRunWorkflow } from "./workflow.js";
import {
  authorize,
  type Permission,
  type Role,
  type SecurityContext,
} from "@conclave/security";

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
  readonly CONCLAVE_AUTH_TOKEN?: string;
  readonly CONCLAVE_AUTH_USER_ID?: string;
  readonly CONCLAVE_AUTH_ORGANIZATION_ID?: string;
  readonly CONCLAVE_ALLOW_ANONYMOUS_DEV?: string;
  readonly CONCLAVE_CI_INGEST_TOKEN?: string;
  readonly CONCLAVE_FORGE_CALLBACK_TOKEN?: string;
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

async function securityContext(
  request: Request,
  env: SecurityEnv,
): Promise<SecurityContext> {
  if (anonymousDevelopment(env)) {
    return {
      userId: "local-development",
      organizationId: "local-development",
      organizationRoles: ["owner"],
      projectRoles: {},
    };
  }
  const token = bearer(request);
  if (!token || !env.CONCLAVE_AUTH_TOKEN || token !== env.CONCLAVE_AUTH_TOKEN)
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
  const projects = await env.CONCLAVE_DB.prepare(
    "SELECT project_id, role FROM project_memberships WHERE project_id IN (SELECT id FROM projects WHERE organization_id = ?1) AND user_id = ?2",
  )
    .bind(organizationId, userId)
    .all<{ project_id: string; role: string }>();
  const projectRoles: Record<string, readonly Role[]> = {};
  for (const project of projects.results ?? [])
    projectRoles[project.project_id] = [project.role as Role];
  return {
    userId,
    organizationId,
    organizationRoles: [membership.role as Role],
    projectRoles,
  };
}

async function authorizeRequest(
  request: Request,
  env: SecurityEnv,
  permission: Permission,
  projectId?: string,
): Promise<SecurityContext> {
  const context = await securityContext(request, env);
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

async function handleRunRequest(request: Request, env: Env): Promise<Response> {
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
  const context = await authorizeRequest(request, securityEnv, "run:create");
  const projectId = anonymousDevelopment(securityEnv)
    ? undefined
    : await goalProjectId(securityEnv, goalId);
  await authorizeRequest(request, securityEnv, "run:create", projectId);
  const params: ConclaveWorkflowParams = {
    runId: requiredString(body.runId, "runId"),
    goalId,
    idempotencyKey,
    organizationId: context.organizationId,
    ...(typeof body.repositoryId === "string"
      ? { repositoryId: body.repositoryId }
      : {}),
    ...(typeof body.revision === "string" ? { revision: body.revision } : {}),
    ...(body.requireApproval === true ? { requireApproval: true } : {}),
    ...(body.requireCiEvidence === false ? { requireCiEvidence: false } : {}),
    ...(body.startPaused === true ? { startPaused: true } : {}),
  };
  const run = await createOrGetRun(env, params);
  return json(run, { status: 202 });
}

async function handleStudioSnapshot(
  env: Env,
  request: Request,
  projectId: string | null,
): Promise<Response> {
  const securityEnv = env as SecurityEnv;
  const context = await authorizeRequest(
    request,
    securityEnv,
    "project:read",
    projectId ?? undefined,
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
  ]);
  const mapJson = (value: unknown): string[] =>
    typeof value === "string" ? (JSON.parse(value) as string[]) : [];
  return json({
    activeRunId: activeRun?.id ?? null,
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

async function handleRunCommand(
  request: Request,
  env: Env,
  runId: string,
  command:
    "pause" | "resume" | "restart" | "event" | "ci-evidence" | "forge-terminal",
): Promise<Response> {
  const securityEnv = env as SecurityEnv;
  if (command === "ci-evidence") requireCiAuthentication(request, securityEnv);
  if (command === "forge-terminal") {
    requireForgeCallbackAuthentication(request, securityEnv);
  } else {
    const projectId = anonymousDevelopment(securityEnv)
      ? undefined
      : await runProjectId(securityEnv, runId);
    await authorizeRequest(request, securityEnv, "run:control", projectId);
  }
  const workflowInstanceId = await resolveWorkflowInstanceId(env, runId);
  const instance = await env.CONCLAVE_RUN_WORKFLOW.get(workflowInstanceId);
  if (command === "pause") await instance.pause();
  if (command === "resume") await instance.resume();
  if (command === "restart") await instance.restart();
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
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true, environment: env.CONCLAVE_ENVIRONMENT });
    }

    try {
      if (request.method === "POST" && url.pathname === "/api/runs") {
        return await handleRunRequest(request, env);
      }
      if (request.method === "GET" && url.pathname === "/api/studio/snapshot") {
        return await handleStudioSnapshot(
          env,
          request,
          url.searchParams.get("projectId"),
        );
      }
      const runMatch = url.pathname.match(
        /^\/api\/runs\/([^/]+)(?:\/(pause|resume|restart|events|ci-evidence|forge-events))?$/,
      );
      if (runMatch?.[1] && request.method === "GET" && !runMatch[2]) {
        const securityEnv = env as SecurityEnv;
        const projectId = anonymousDevelopment(securityEnv)
          ? undefined
          : await runProjectId(securityEnv, runMatch[1]);
        await authorizeRequest(request, securityEnv, "project:read", projectId);
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
                : (runMatch[2] as "pause" | "resume" | "restart");
        return await handleRunCommand(request, env, runMatch[1], command);
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
