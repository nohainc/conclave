import { afterEach, describe, expect, it, vi } from "vitest";
import { hashToken } from "../../../packages/security/src/index.js";
import {
  isCurrentWorkspaceSocket,
  isWorkspaceRuntimeAuthorized,
  normalizeWorkspaceWorkerInstallationStatus,
  WorkspaceGateway,
  workspaceAssignmentContextMatches,
} from "../src/workspace-gateway.js";

describe("Workspace runtime Gateway", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("authenticates HTTP runtime sessions with the runtime credential and polls the Gateway queue", async () => {
    const token = "runtime-secret-for-http-fallback";
    const credentialTokenHash = await hashToken(token);
    const workspaceId = "workspace-http-fallback";
    const values: unknown[][] = [];
    const db = {
      prepare(sql: string) {
        return {
          bind: (...bound: unknown[]) => ({
            first: async () =>
              sql.includes("FROM worker_assignments")
                ? {
                    id: "assignment-http-fallback",
                    execution_workspace_id: workspaceId,
                    runtime_identity_id: "runtime-http-fallback",
                    worker_id: "worker-http-fallback",
                    workspace_worker_id: "worker-http-fallback",
                    run_id: "run-http-fallback",
                    task_id: "task-http-fallback",
                    attempt_id: "attempt-http-fallback",
                    idempotency_key: "idem-http-fallback",
                    status: "created",
                  }
                : {
                    executionWorkspaceId: workspaceId,
                    credentialTokenHash,
                  },
            run: async () => {
              values.push(bound);
              return { success: true };
            },
          }),
        };
      },
    };
    const storage = new Map<string, unknown>();
    const state = {
      id: { name: workspaceId },
      storage: {
        get: async (key: string) => storage.get(key),
        put: async (key: string, value: unknown) => {
          storage.set(key, value);
        },
        delete: async (key: string) => storage.delete(key),
      },
    };
    const gateway = new WorkspaceGateway(state as never, {
      CONCLAVE_DB: db as never,
    });
    const humanCredentialAttempt = await gateway.fetch(
      new Request("https://gateway.internal/runtime/sessions", {
        method: "POST",
        headers: {
          authorization: "Bearer conclave_dhs_human-session",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          workspaceRuntimeId: "runtime-http-fallback",
          contractVersion: "1.0",
        }),
      }),
    );
    expect(humanCredentialAttempt.status).toBe(401);
    const create = await gateway.fetch(
      new Request("https://gateway.internal/runtime/sessions", {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          workspaceRuntimeId: "runtime-http-fallback",
          contractVersion: "1.0",
        }),
      }),
    );
    expect(create.status).toBe(200);
    const created = (await create.json()) as {
      sessionId: string;
      cursor: string;
    };
    expect(created.cursor).toBe("0");
    expect(values).toHaveLength(3);
    const status = await gateway.fetch(
      new Request("https://gateway.internal/status"),
    );
    expect(await status.json()).toMatchObject({
      online: true,
      activeTransport: "http_long_poll",
      sessionId: created.sessionId,
    });

    const dispatch = await gateway.fetch(
      new Request("https://gateway.internal/dispatch-assignment", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          executionWorkspaceId: workspaceId,
          workspaceRuntimeId: "runtime-http-fallback",
          workerId: "worker-http-fallback",
          runId: "run-http-fallback",
          taskId: "task-http-fallback",
          attemptId: "attempt-http-fallback",
          assignmentId: "assignment-http-fallback",
          idempotencyKey: "idem-http-fallback",
          payload: { input: "fallback assignment" },
        }),
      }),
    );
    expect(dispatch.status).toBe(200);
    expect(await dispatch.json()).toEqual({ delivered: true });
    const assignmentPoll = await gateway.fetch(
      new Request("https://gateway.internal/runtime/poll", {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          sessionId: created.sessionId,
          cursor: created.cursor,
          waitMs: 0,
        }),
      }),
    );
    expect(assignmentPoll.status).toBe(200);
    const delivered = (await assignmentPoll.json()) as { cursor: string };
    expect(delivered).toMatchObject({
      events: [
        {
          message: {
            type: "assignment.start",
            assignmentId: "assignment-http-fallback",
          },
        },
      ],
    });

    const rejected = await gateway.fetch(
      new Request("https://gateway.internal/runtime/poll", {
        method: "POST",
        headers: {
          authorization: "Bearer wrong-runtime-credential",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          sessionId: created.sessionId,
          cursor: delivered.cursor,
          waitMs: 0,
        }),
      }),
    );
    expect(rejected.status).toBe(401);

    const poll = await gateway.fetch(
      new Request("https://gateway.internal/runtime/poll", {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          sessionId: created.sessionId,
          cursor: delivered.cursor,
          waitMs: 0,
        }),
      }),
    );
    expect(poll.status).toBe(200);
    expect(await poll.json()).toMatchObject({
      cursor: delivered.cursor,
      events: [],
      timedOut: true,
    });
  });

  it("deduplicates replayed runtime events across HTTP session recreation", async () => {
    const token = "runtime-secret-replay";
    const credentialTokenHash = await hashToken(token);
    const workspaceId = "workspace-replay";
    const db = {
      prepare(_sql: string) {
        return {
          bind: () => ({
            first: async () => ({
              executionWorkspaceId: workspaceId,
              credentialTokenHash,
            }),
            run: async () => ({ success: true }),
          }),
        };
      },
    };
    const storage = new Map<string, unknown>();
    const state = {
      id: { name: workspaceId },
      storage: {
        get: async (key: string) => storage.get(key),
        put: async (key: string, value: unknown) => {
          storage.set(key, value);
        },
        delete: async (key: string) => storage.delete(key),
      },
    };
    const gateway = new WorkspaceGateway(state as never, {
      CONCLAVE_DB: db as never,
    });
    const createSession = async () => {
      const response = await gateway.fetch(
        new Request("https://gateway.internal/runtime/sessions", {
          method: "POST",
          headers: {
            authorization: `Bearer ${token}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            workspaceRuntimeId: "runtime-replay",
            contractVersion: "1.0",
          }),
        }),
      );
      expect(response.status).toBe(200);
      return (await response.json()) as { sessionId: string; cursor: string };
    };
    const firstSession = await createSession();
    const replayedEvent = {
      contract: "conclave.desktop-auth-transport",
      version: "1.0",
      eventId: "stable-replay-event-id",
      occurredAt: new Date().toISOString(),
      message: {
        protocol: "conclave.workspace-runtime-protocol",
        protocolVersion: "5.1",
        messageId: "stable-protocol-message-id",
        timestamp: new Date().toISOString(),
        type: "workspace.heartbeat",
        executionWorkspaceId: workspaceId,
        workspaceRuntimeId: "runtime-replay",
        payload: {},
      },
    };
    const postEvent = (sessionId: string) =>
      gateway.fetch(
        new Request("https://gateway.internal/runtime/events", {
          method: "POST",
          headers: {
            authorization: `Bearer ${token}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({ sessionId, events: [replayedEvent] }),
        }),
      );
    const firstPost = await postEvent(firstSession.sessionId);
    expect(await firstPost.json()).toMatchObject({
      acceptedEventIds: ["stable-replay-event-id"],
      rejected: [],
    });

    const nextSession = await createSession();
    const replay = await postEvent(nextSession.sessionId);
    expect(await replay.json()).toMatchObject({
      acceptedEventIds: ["stable-replay-event-id"],
      rejected: [],
    });
    const poll = await gateway.fetch(
      new Request("https://gateway.internal/runtime/poll", {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          sessionId: nextSession.sessionId,
          cursor: nextSession.cursor,
          waitMs: 0,
        }),
      }),
    );
    expect(await poll.json()).toMatchObject({ events: [], timedOut: true });
  });

  it("rejects a previous runtime's cursor after another runtime takes the Gateway", async () => {
    const tokens = {
      "runtime-a": "runtime-secret-a",
      "runtime-b": "runtime-secret-b",
    };
    const workspaceId = "workspace-cursor-isolation";
    const tokenHashes = {
      "runtime-a": await hashToken(tokens["runtime-a"]),
      "runtime-b": await hashToken(tokens["runtime-b"]),
    };
    const db = {
      prepare(sql: string) {
        return {
          bind: (...bound: unknown[]) => ({
            first: async () => {
              if (sql.includes("FROM worker_assignments"))
                return {
                  id: "assignment-cursor-test",
                  execution_workspace_id: workspaceId,
                  runtime_identity_id: "runtime-a",
                  worker_id: "worker-a",
                  workspace_worker_id: "worker-a",
                  run_id: "run-a",
                  task_id: "task-a",
                  attempt_id: "attempt-a",
                  idempotency_key: "idem-a",
                  status: "created",
                };
              const runtimeId = String(bound[0]);
              return {
                executionWorkspaceId: workspaceId,
                credentialTokenHash:
                  tokenHashes[runtimeId as keyof typeof tokenHashes],
              };
            },
            run: async () => ({ success: true }),
          }),
        };
      },
    };
    const storage = new Map<string, unknown>();
    const state = {
      id: { name: workspaceId },
      storage: {
        get: async (key: string) => storage.get(key),
        put: async (key: string, value: unknown) => {
          storage.set(key, value);
        },
        delete: async (key: string) => storage.delete(key),
      },
    };
    const gateway = new WorkspaceGateway(state as never, {
      CONCLAVE_DB: db as never,
    });
    const createSession = async (runtimeId: string) => {
      const response = await gateway.fetch(
        new Request("https://gateway.internal/runtime/sessions", {
          method: "POST",
          headers: {
            authorization: `Bearer ${tokens[runtimeId as keyof typeof tokens]}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            workspaceRuntimeId: runtimeId,
            contractVersion: "1.0",
          }),
        }),
      );
      expect(response.status).toBe(200);
      return (await response.json()) as { sessionId: string; cursor: string };
    };
    const firstSession = await createSession("runtime-a");
    const dispatch = await gateway.fetch(
      new Request("https://gateway.internal/dispatch-assignment", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          executionWorkspaceId: workspaceId,
          workspaceRuntimeId: "runtime-a",
          workerId: "worker-a",
          runId: "run-a",
          taskId: "task-a",
          attemptId: "attempt-a",
          assignmentId: "assignment-cursor-test",
          idempotencyKey: "idem-a",
          payload: {},
        }),
      }),
    );
    expect(dispatch.status).toBe(200);
    const firstPoll = await gateway.fetch(
      new Request("https://gateway.internal/runtime/poll", {
        method: "POST",
        headers: {
          authorization: `Bearer ${tokens["runtime-a"]}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          sessionId: firstSession.sessionId,
          cursor: firstSession.cursor,
          waitMs: 0,
        }),
      }),
    );
    const priorRuntimeEvents = (await firstPoll.json()) as { cursor: string };
    expect(priorRuntimeEvents.cursor).toBe("1");

    const secondSession = await createSession("runtime-b");
    const staleCursor = await gateway.fetch(
      new Request("https://gateway.internal/runtime/poll", {
        method: "POST",
        headers: {
          authorization: `Bearer ${tokens["runtime-b"]}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          sessionId: secondSession.sessionId,
          cursor: priorRuntimeEvents.cursor,
          waitMs: 0,
        }),
      }),
    );
    expect(staleCursor.status).toBe(400);
    const cleanPoll = await gateway.fetch(
      new Request("https://gateway.internal/runtime/poll", {
        method: "POST",
        headers: {
          authorization: `Bearer ${tokens["runtime-b"]}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          sessionId: secondSession.sessionId,
          cursor: secondSession.cursor,
          waitMs: 0,
        }),
      }),
    );
    expect(await cleanPoll.json()).toMatchObject({
      events: [],
      timedOut: true,
    });
  });

  it("logs DO upgrade checkpoints with the forwarded request correlation ID", async () => {
    const runtimeToken = "runtime-secret-for-gateway-test";
    const credentialTokenHash = await hashToken(runtimeToken);
    const workspaceId = "workspace-gateway-test";
    let resolveHelloAck!: (message: string) => void;
    const helloAck = new Promise<string>((resolve) => {
      resolveHelloAck = resolve;
    });
    class TestSocket {
      attachment?: unknown;
      serializeAttachment(value: unknown) {
        this.attachment = value;
      }
      deserializeAttachment() {
        return this.attachment;
      }
      send(message: string) {
        if (
          (JSON.parse(message) as { type?: string }).type ===
          "workspace.hello.ack"
        ) {
          resolveHelloAck(message);
        }
      }
      close() {}
    }
    let acceptedSocket: TestSocket | undefined;
    class TestWebSocketPair {
      0 = new TestSocket();
      1 = new TestSocket();
    }
    class TestResponse {
      readonly status: number;
      readonly webSocket?: unknown;
      constructor(
        _body: unknown,
        init?: { status?: number; webSocket?: unknown },
      ) {
        this.status = init?.status ?? 200;
        this.webSocket = init?.webSocket;
      }
      static json(body: unknown, init?: { status?: number }) {
        return new TestResponse(body, init);
      }
    }
    vi.stubGlobal("WebSocketPair", TestWebSocketPair);
    vi.stubGlobal("Response", TestResponse);
    const db = {
      prepare(_sql: string) {
        return {
          bind: (..._values: unknown[]) => ({
            first: async () => ({
              executionWorkspaceId: workspaceId,
              credentialTokenHash,
            }),
            run: async () => ({ success: true }),
          }),
        };
      },
    };
    const state = {
      id: { name: workspaceId },
      storage: {
        get: async () => undefined,
        put: async () => undefined,
        delete: async () => undefined,
      },
      acceptWebSocket(socket: unknown) {
        acceptedSocket = socket as TestSocket;
      },
    };
    const gateway = new WorkspaceGateway(state as never, {
      CONCLAVE_DB: db as never,
    });
    const logs: string[] = [];
    vi.spyOn(console, "log").mockImplementation((record) => {
      logs.push(String(record));
    });
    vi.spyOn(console, "warn").mockImplementation((record) => {
      logs.push(String(record));
    });
    vi.spyOn(console, "error").mockImplementation((record) => {
      logs.push(String(record));
    });

    const response = (await gateway.fetch(
      new Request(
        `https://app.conclave.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-gateway-test`,
        {
          headers: {
            upgrade: "websocket",
            authorization: `Bearer ${runtimeToken}`,
            "cf-ray": "gateway-ray-456",
          },
        },
      ),
    )) as unknown as TestResponse;

    expect(response.status).toBe(101);
    expect(acceptedSocket).toBeDefined();
    expect(acceptedSocket?.attachment).toMatchObject({
      correlationId: "gateway-ray-456",
      executionWorkspaceId: workspaceId,
      workspaceRuntimeId: "runtime-gateway-test",
    });
    gateway.webSocketMessage(
      acceptedSocket as unknown as WebSocket,
      JSON.stringify({
        protocol: "conclave.workspace-runtime-protocol",
        protocolVersion: "5.1",
        messageId: "gateway-hello-message",
        timestamp: new Date().toISOString(),
        type: "workspace.hello",
        executionWorkspaceId: workspaceId,
        workspaceRuntimeId: "runtime-gateway-test",
        payload: {},
      }),
    );
    await helloAck;
    const records = logs.map(
      (record) =>
        JSON.parse(record) as {
          message: string;
          correlation?: { requestId?: string };
        },
    );
    expect(records.map((record) => record.message)).toEqual([
      "GW-05 durable_object_request_received",
      "GW-06 durable_object_runtime_authenticated",
      "GW-07 websocket_accepting",
      "GW-08 websocket_accepted",
      "GW-09 returning_http_101",
      "GW-10 workspace_hello_received",
      "GW-11 workspace_hello_ack_sent",
    ]);
    expect(
      records.every(
        (record) => record.correlation?.requestId === "gateway-ray-456",
      ),
    ).toBe(true);
    expect(logs.join("\n")).not.toContain(runtimeToken);
  });

  it("accepts only the runtime credential for one execution Workspace", async () => {
    const db = {
      prepare(query: string) {
        return {
          bind(runtimeId: string, tokenHash: string) {
            return {
              first: async () =>
                query.includes("credential_token_hash") &&
                runtimeId === "runtime-a" &&
                tokenHash === "hash-a"
                  ? { executionWorkspaceId: "workspace-a" }
                  : null,
            };
          },
        };
      },
    } as never;

    await expect(
      isWorkspaceRuntimeAuthorized(db, "runtime-a", "hash-a"),
    ).resolves.toEqual({ executionWorkspaceId: "workspace-a" });
    await expect(
      isWorkspaceRuntimeAuthorized(db, "runtime-a", "wrong-token"),
    ).resolves.toBeNull();
    await expect(
      isWorkspaceRuntimeAuthorized(db, "runtime-revoked", "hash-a"),
    ).resolves.toBeNull();
  });

  it("fences stale socket close events after reconnect", () => {
    const current = {} as WebSocket;
    const stale = {} as WebSocket;
    expect(isCurrentWorkspaceSocket(current, "new", current, "new")).toBe(true);
    expect(isCurrentWorkspaceSocket(current, "new", stale, "old")).toBe(false);
  });

  it("rejects assignment correlation for another Workspace runtime", () => {
    const row = {
      id: "assignment-1",
      execution_workspace_id: "workspace-a",
      runtime_identity_id: "runtime-a",
      worker_id: "worker-1",
      run_id: "run-1",
      task_id: "task-1",
      attempt_id: "attempt-1",
      idempotency_key: "idem-1",
    };
    const message = {
      executionWorkspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      workerId: "worker-1",
      runId: "run-1",
      taskId: "task-1",
      attemptId: "attempt-1",
      assignmentId: "assignment-1",
      idempotencyKey: "idem-1",
    };
    expect(workspaceAssignmentContextMatches(message, row)).toBe(true);
    expect(
      workspaceAssignmentContextMatches(
        { ...message, workspaceRuntimeId: "runtime-b" },
        row,
      ),
    ).toBe(false);
    expect(
      workspaceAssignmentContextMatches(
        { ...message, executionWorkspaceId: "workspace-b" },
        row,
      ),
    ).toBe(false);
  });

  it("normalizes runtime Worker health without allowing it to change desired state", () => {
    expect(normalizeWorkspaceWorkerInstallationStatus("ready")).toBe("ready");
    expect(normalizeWorkspaceWorkerInstallationStatus("downloading")).toBe(
      "installing",
    );
    expect(normalizeWorkspaceWorkerInstallationStatus("updating")).toBe(
      "updating",
    );
    expect(normalizeWorkspaceWorkerInstallationStatus("unknown")).toBe(
      "failed",
    );
  });
});
