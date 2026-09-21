import type {
  RuntimeEvidence,
  RuntimeOperation,
  RuntimeWorkerDescriptor,
  RuntimeWorkerExecutionRequest,
  RuntimeWorkerExecutionResult,
} from "@conclave/local-runtime";

interface RuntimeConnectionScope {
  readonly organizationId: string;
  readonly projectId: string;
  readonly runId?: string;
  readonly taskId?: string;
  readonly repositoryId?: string;
}

type RuntimeMessage =
  | { readonly type: "operation"; readonly operation: RuntimeOperation }
  | { readonly type: "cancel"; readonly requestId: string }
  | { readonly type: "evidence"; readonly evidence: RuntimeEvidence }
  | {
      readonly type: "workers";
      readonly workers: readonly RuntimeWorkerDescriptor[];
    }
  | RuntimeWorkerExecutionRequest
  | RuntimeWorkerExecutionResult
  | { readonly type: "ack"; readonly requestId: string };

export class RuntimeConnection implements DurableObject {
  private socket: WebSocket | null = null;
  private scope: RuntimeConnectionScope | null = null;
  private workers: readonly RuntimeWorkerDescriptor[] = [];
  private readonly pending = new Map<
    string,
    {
      resolve: (evidence: RuntimeEvidence) => void;
      reject: (error: Error) => void;
    }
  >();

  constructor(_state: DurableObjectState, _env: Env) {
    void _state;
    void _env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.headers.get("Upgrade")?.toLowerCase() === "websocket") {
      return this.openConnection(request, url);
    }
    if (request.method === "POST" && url.pathname === "/execute") {
      return this.execute(await request.json());
    }
    if (request.method === "POST" && url.pathname === "/cancel") {
      const body = (await request.json()) as { requestId?: unknown };
      if (typeof body.requestId !== "string")
        return Response.json(
          { error: "requestId is required" },
          { status: 400 },
        );
      this.socket?.send(
        JSON.stringify({
          type: "cancel",
          requestId: body.requestId,
        } satisfies RuntimeMessage),
      );
      return Response.json({ acknowledged: true });
    }
    if (request.method === "GET" && url.pathname === "/workers") {
      return Response.json({ workers: this.workers });
    }
    if (request.method === "POST" && url.pathname === "/worker-execute") {
      return this.executeWorker(await request.json());
    }
    return Response.json({ error: "not_found" }, { status: 404 });
  }

  private openConnection(request: Request, url: URL): Response {
    const scope = this.parseScope(url.searchParams);
    if (!scope)
      return Response.json(
        { error: "runtime scope is incomplete" },
        { status: 400 },
      );
    const pair = new WebSocketPair();
    const server = pair[1];
    server.accept();
    this.socket = server;
    this.scope = scope;
    server.addEventListener("message", (event) => {
      void this.receive(event.data);
    });
    server.addEventListener("close", () => {
      this.socket = null;
      for (const pending of this.pending.values()) {
        pending.reject(new Error("Local Runtime connection closed"));
      }
      this.pending.clear();
      for (const pending of this.pendingWorkers.values()) {
        pending.reject(new Error("Local Runtime connection closed"));
      }
      this.pendingWorkers.clear();
    });
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  private async execute(value: unknown): Promise<Response> {
    if (!this.socket || !this.scope)
      return Response.json(
        { error: "Local Runtime is offline" },
        { status: 503 },
      );
    if (!this.matchesScope(value))
      return Response.json(
        { error: "Runtime operation scope mismatch" },
        { status: 403 },
      );
    const operation = value as RuntimeOperation;
    const evidence = await new Promise<RuntimeEvidence>((resolve, reject) => {
      this.pending.set(operation.requestId, { resolve, reject });
      this.socket?.send(
        JSON.stringify({
          type: "operation",
          operation,
        } satisfies RuntimeMessage),
      );
    });
    return Response.json(evidence);
  }

  private async executeWorker(value: unknown): Promise<Response> {
    if (!this.socket || !this.scope)
      return Response.json(
        { error: "Local Runtime is offline" },
        { status: 503 },
      );
    if (typeof value !== "object" || value === null)
      return Response.json(
        { error: "worker request must be an object" },
        { status: 400 },
      );
    const envelope = value as RuntimeWorkerExecutionRequest;
    if (
      envelope.type !== "worker_execute" ||
      !this.matchesWorkerScope(envelope) ||
      typeof envelope.request !== "object" ||
      envelope.request === null
    ) {
      return Response.json(
        { error: "Worker execution scope mismatch" },
        { status: 403 },
      );
    }
    const worker = this.workers.find(
      (candidate) =>
        candidate.workerId === envelope.request.workerId &&
        candidate.connectionId === envelope.request.connectionId,
    );
    if (!worker || worker.availability !== "available") {
      return Response.json(
        { error: "Local worker is unavailable" },
        { status: 503 },
      );
    }
    const result = await new Promise<RuntimeWorkerExecutionResult>(
      (resolve, reject) => {
        this.pendingWorkers.set(envelope.request.requestId, {
          resolve,
          reject,
        });
        this.socket?.send(JSON.stringify(envelope));
      },
    );
    return Response.json(result.result);
  }

  private async receive(value: unknown): Promise<void> {
    let message: RuntimeMessage;
    try {
      message = JSON.parse(
        typeof value === "string"
          ? value
          : new TextDecoder().decode(value as ArrayBuffer),
      ) as RuntimeMessage;
    } catch {
      this.socket?.send(
        JSON.stringify({ type: "error", error: "invalid runtime message" }),
      );
      return;
    }
    if (message.type === "evidence") {
      const pending = this.pending.get(message.evidence.requestId);
      if (!pending) return;
      this.pending.delete(message.evidence.requestId);
      pending.resolve(message.evidence);
      this.socket?.send(
        JSON.stringify({
          type: "ack",
          requestId: message.evidence.requestId,
        } satisfies RuntimeMessage),
      );
    }
    if (message.type === "workers") {
      this.workers = message.workers;
      return;
    }
    if (message.type === "worker_result") {
      const pending = this.pendingWorkers.get(message.requestId);
      if (!pending) return;
      this.pendingWorkers.delete(message.requestId);
      pending.resolve(message);
    }
  }

  private readonly pendingWorkers = new Map<
    string,
    {
      resolve: (result: RuntimeWorkerExecutionResult) => void;
      reject: (error: Error) => void;
    }
  >();

  private parseScope(params: URLSearchParams): RuntimeConnectionScope | null {
    const values = {
      organizationId: params.get("organizationId"),
      projectId: params.get("projectId"),
      runId: params.get("runId"),
      taskId: params.get("taskId"),
      repositoryId: params.get("repositoryId"),
    };
    if (
      typeof values.organizationId !== "string" ||
      typeof values.projectId !== "string" ||
      values.organizationId.length === 0 ||
      values.projectId.length === 0
    )
      return null;
    return {
      organizationId: values.organizationId,
      projectId: values.projectId,
      ...(values.runId ? { runId: values.runId } : {}),
      ...(values.taskId ? { taskId: values.taskId } : {}),
      ...(values.repositoryId ? { repositoryId: values.repositoryId } : {}),
    };
  }

  private matchesScope(value: unknown): boolean {
    if (typeof value !== "object" || value === null || !this.scope)
      return false;
    const operation = value as Record<string, unknown>;
    return [
      "organizationId",
      "projectId",
      "runId",
      "taskId",
      "repositoryId",
    ].every((field) => {
      const scoped = this.scope?.[field as keyof RuntimeConnectionScope];
      return scoped === undefined || operation[field] === scoped;
    });
  }

  private matchesWorkerScope(value: unknown): boolean {
    if (typeof value !== "object" || value === null || !this.scope)
      return false;
    const envelope = value as Record<string, unknown>;
    return (
      envelope.organizationId === this.scope.organizationId &&
      envelope.projectId === this.scope.projectId
    );
  }
}
