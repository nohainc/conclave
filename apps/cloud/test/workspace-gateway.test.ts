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
    const statements: string[] = [];
    const db = {
      prepare(sql: string) {
        statements.push(sql);
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
    expect(statements).toHaveLength(4);
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
