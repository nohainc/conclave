import {
  InteractiveConnector,
  InteractiveConnectorError,
  type ConnectorSessionRegistration,
  type ConnectorStatus,
} from "@conclave/core";

type ConnectorEnv = Env & {
  readonly CONCLAVE_CONNECTOR_REGISTRATION_TOKEN?: string;
};

const connectors = new Map<string, InteractiveConnector>();

function bearer(request: Request): string | null {
  const value = request.headers.get("authorization");
  return value?.startsWith("Bearer ") ? value.slice(7) : null;
}

function connector(env: ConnectorEnv): InteractiveConnector {
  const token = env.CONCLAVE_CONNECTOR_REGISTRATION_TOKEN;
  if (!token)
    throw new InteractiveConnectorError(
      "Connector authentication is not configured",
      "unauthorized",
    );
  const existing = connectors.get(token);
  if (existing) return existing;
  const created = new InteractiveConnector({ registrationToken: token });
  connectors.set(token, created);
  return created;
}

export async function handleConnectorRequest(
  request: Request,
  env: ConnectorEnv,
  action: string,
): Promise<Response> {
  const service = connector(env);
  const body = (await request.json()) as Record<string, unknown>;
  const sessionId = typeof body.sessionId === "string" ? body.sessionId : "";
  const sessionToken = bearer(request) ?? "";
  if (action === "register_session") {
    return Response.json(
      service.registerSession(
        sessionToken,
        body as unknown as ConnectorSessionRegistration,
      ),
    );
  }
  if (!sessionId || !sessionToken) {
    throw new InteractiveConnectorError(
      "Connector session authentication required",
      "unauthorized",
    );
  }
  const taskId = typeof body.taskId === "string" ? body.taskId : "";
  switch (action) {
    case "claim_task":
      return Response.json({
        task: service.claimTask(sessionId, sessionToken, taskId || undefined),
      });
    case "get_task":
      return Response.json({
        task: service.getTask(sessionId, sessionToken, taskId),
      });
    case "get_context":
      return Response.json({
        context: service.getContext(sessionId, sessionToken, taskId),
      });
    case "get_next_message":
      return Response.json({
        message: service.getNextMessage(sessionId, sessionToken, taskId),
      });
    case "submit_candidate":
      service.submitCandidate(sessionId, sessionToken, taskId, body.candidate);
      return Response.json({ accepted: true });
    case "submit_result":
      service.submitResult(sessionId, sessionToken, taskId, body.result);
      return Response.json({ accepted: true });
    case "submit_finding":
      service.submitFinding(sessionId, sessionToken, taskId, body.finding);
      return Response.json({ accepted: true });
    case "report_status":
      service.reportStatus(
        sessionId,
        sessionToken,
        body.status as ConnectorStatus,
      );
      return Response.json({ accepted: true });
    case "release_task":
      service.releaseTask(sessionId, sessionToken, taskId);
      return Response.json({ released: true });
    default:
      return Response.json({ error: "not_found" }, { status: 404 });
  }
}

export async function handleConnectorTaskRequest(
  request: Request,
  env: ConnectorEnv,
  taskId?: string,
): Promise<Response> {
  const service = connector(env);
  const token = bearer(request) ?? "";
  if (request.method === "POST" && !taskId) {
    const body = (await request.json()) as Record<string, unknown>;
    service.registerTask({
      taskId:
        typeof body.taskId === "string" ? body.taskId : crypto.randomUUID(),
      goalId: typeof body.goalId === "string" ? body.goalId : "web-goal",
      runId: typeof body.runId === "string" ? body.runId : "web-run",
      objective: typeof body.objective === "string" ? body.objective : "",
      context: [],
      messages: [body.prompt ?? body.input ?? {}],
    });
    return Response.json({ accepted: true });
  }
  if (request.method === "GET" && taskId) {
    return Response.json(service.getTaskStatus(token, taskId));
  }
  return Response.json({ error: "not_found" }, { status: 404 });
}
