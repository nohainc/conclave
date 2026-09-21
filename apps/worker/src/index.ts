export { ConclaveRunWorkflow } from "./workflow.js";

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

function workflowId(idempotencyKey: string): string {
  return `run-${idempotencyKey}`;
}

async function createOrGetRun(
  env: Env,
  params: ConclaveWorkflowParams,
): Promise<{ id: string; status: unknown }> {
  const id = workflowId(params.idempotencyKey);
  try {
    const instance = await env.CONCLAVE_RUN_WORKFLOW.create({ id, params });
    return { id: instance.id, status: (await instance.status()).status };
  } catch (error) {
    if (!errorMessage(error).toLowerCase().includes("exist")) throw error;
    const instance = await env.CONCLAVE_RUN_WORKFLOW.get(id);
    return { id: instance.id, status: (await instance.status()).status };
  }
}

type ConclaveWorkflowParams = import("./workflow.js").ConclaveWorkflowParams;

async function handleRunRequest(request: Request, env: Env): Promise<Response> {
  const body = (await request.json()) as Record<string, unknown>;
  const idempotencyKey = requiredString(
    request.headers.get("idempotency-key") ?? body.idempotencyKey,
    "idempotencyKey",
  );
  if (!/^[a-zA-Z0-9_-]{1,80}$/.test(idempotencyKey)) {
    throw new Error("idempotencyKey must contain only letters, digits, _ or -");
  }
  const params: ConclaveWorkflowParams = {
    runId: requiredString(body.runId, "runId"),
    goalId: requiredString(body.goalId, "goalId"),
    idempotencyKey,
    ...(body.requireApproval === true ? { requireApproval: true } : {}),
    ...(body.requireCiEvidence === false ? { requireCiEvidence: false } : {}),
  };
  const run = await createOrGetRun(env, params);
  return json(run, { status: 202 });
}

async function handleStudioSnapshot(
  env: Env,
  projectId: string | null,
): Promise<Response> {
  const projectFilter = projectId === null ? "" : " WHERE p.id = ?1";
  const bind = projectId === null ? [] : [projectId];
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
      "SELECT id, name, provider, roles_json, capabilities_json, availability AS status, '' AS cost FROM workers ORDER BY name",
    ).all(),
    env.CONCLAVE_DB.prepare(
      "SELECT t.id, t.objective AS title, p.name AS phase, t.status, t.role AS worker, t.objective AS detail, CASE WHEN t.status = 'completed' THEN 1 ELSE 0 END AS progress, '[]' AS dependencies, '—' AS tokens, '—' AS cost FROM tasks t JOIN phases p ON p.id = t.phase_id ORDER BY t.created_at DESC LIMIT 100",
    ).all(),
    env.CONCLAVE_DB.prepare(
      "SELECT id, description AS title, description, severity, status, COALESCE(task_id, '') AS taskId, 'Unknown' AS author FROM findings ORDER BY created_at DESC LIMIT 100",
    ).all(),
    env.CONCLAVE_DB.prepare(
      "SELECT occurred_at AS time, event_type AS title, entity_id AS detail, event_type AS kind FROM run_events ORDER BY occurred_at DESC LIMIT 100",
    ).all(),
    env.CONCLAVE_DB.prepare(
      "SELECT id AS name, media_type AS type, size_bytes AS size, 'Conclave' AS source FROM artifacts ORDER BY created_at DESC LIMIT 100",
    ).all(),
    env.CONCLAVE_DB.prepare(
      "SELECT worker_id AS worker, model, attempt_id AS task, input_tokens + output_tokens AS tokens, estimated_cost_micros AS cost, '—' AS duration, status FROM model_calls ORDER BY started_at DESC LIMIT 100",
    ).all(),
    env.CONCLAVE_DB.prepare(
      "SELECT id FROM runs WHERE status IN ('active', 'running', 'waiting') ORDER BY created_at DESC LIMIT 1",
    ).first<{ id: string }>(),
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
  command: "pause" | "resume" | "restart" | "event" | "ci-evidence",
): Promise<Response> {
  const instance = await env.CONCLAVE_RUN_WORKFLOW.get(runId);
  if (command === "pause") await instance.pause();
  if (command === "resume") await instance.resume();
  if (command === "restart") await instance.restart();
  if (command === "event" || command === "ci-evidence") {
    if (command === "ci-evidence") {
      const configuredToken = (
        env as Env & {
          CONCLAVE_CI_INGEST_TOKEN?: string;
        }
      ).CONCLAVE_CI_INGEST_TOKEN;
      if (
        configuredToken !== undefined &&
        request.headers.get("authorization") !== `Bearer ${configuredToken}`
      ) {
        throw new Error("CI evidence authorization failed");
      }
    }
    const body = (await request.json()) as Record<string, unknown>;
    if (command === "ci-evidence") {
      await instance.sendEvent({
        type: "ci-evidence",
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
  return json({ id: instance.id, status: (await instance.status()).status });
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
          url.searchParams.get("projectId"),
        );
      }
      const runMatch = url.pathname.match(
        /^\/api\/runs\/([^/]+)(?:\/(pause|resume|restart|events|ci-evidence))?$/,
      );
      if (runMatch?.[1] && request.method === "GET" && !runMatch[2]) {
        const instance = await env.CONCLAVE_RUN_WORKFLOW.get(runMatch[1]);
        return json({ id: instance.id, ...(await instance.status()) });
      }
      if (runMatch?.[1] && request.method === "POST" && runMatch[2]) {
        const command =
          runMatch[2] === "events"
            ? "event"
            : runMatch[2] === "ci-evidence"
              ? "ci-evidence"
              : (runMatch[2] as "pause" | "resume" | "restart");
        return await handleRunCommand(request, env, runMatch[1], command);
      }
    } catch (error) {
      return json({ error: errorMessage(error) }, { status: 400 });
    }

    return json({ error: "not_found" }, { status: 404 });
  },
} satisfies ExportedHandler<Env>;
