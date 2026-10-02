import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";
import { hashToken } from "../../../packages/security/src/index.js";
import { WorkspaceGateway } from "../src/workspace-gateway.js";

class LocalD1Statement {
  constructor(
    private readonly db: DatabaseSync,
    private readonly sql: string,
    private readonly values: unknown[] = [],
  ) {}

  bind(...values: unknown[]): LocalD1Statement {
    return new LocalD1Statement(this.db, this.sql, values);
  }

  async first<T>(): Promise<T | null> {
    return (
      (this.db.prepare(this.sql).get(...(this.values as SQLInputValue[])) as
        T | undefined) ?? null
    );
  }

  async all<T>(): Promise<{ results: T[] }> {
    return {
      results: this.db
        .prepare(this.sql)
        .all(...(this.values as SQLInputValue[])) as T[],
    };
  }

  async run(): Promise<{ success: true }> {
    this.db.prepare(this.sql).run(...(this.values as SQLInputValue[]));
    return { success: true };
  }
}

class LocalD1 {
  constructor(readonly sqlite: DatabaseSync) {}

  prepare(sql: string): LocalD1Statement {
    return new LocalD1Statement(this.sqlite, sql);
  }
}

async function waitFor(check: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (check()) return;
    await Promise.resolve();
  }
  throw new Error("Timed out waiting for Workspace Gateway database update");
}

describe("Workspace Gateway active-schema regression", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("supports Gateway connect, heartbeat, and disconnect on migrations-v8 alone", async () => {
    const migrationDirectory = fileURLToPath(
      new URL("../migrations-v8/", import.meta.url),
    );
    const database = new DatabaseSync(":memory:");
    database.exec("PRAGMA foreign_keys = ON");
    const migrationFiles = readdirSync(migrationDirectory)
      .filter((file) => file.endsWith(".sql"))
      .sort();
    for (const migration of migrationFiles) {
      database.exec(readFileSync(join(migrationDirectory, migration), "utf8"));
    }

    const expectedTables = [
      "execution_workspaces",
      "workspace_runtime_identities",
      "workspace_sessions",
      "workspace_runtime_facts",
      "workspace_worker_inventory",
      "worker_scheduling",
      "worker_scheduling_audit",
      "workspace_releases",
      "workspace_pairing_intents",
      "workspace_project_grants",
      "workstream_execution_policies",
      "worker_assignments",
      "worker_catalog",
      "tool_profile_definitions",
      "tool_profile_releases",
      "tool_profile_release_audit",
      "tool_profile_channel_pointers",
    ];
    const actualTables = new Set(
      database
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
        .all()
        .map((row) => String((row as { name: string }).name)),
    );
    expect(expectedTables.filter((table) => !actualTables.has(table))).toEqual(
      [],
    );
    expect(actualTables.has("worker_releases")).toBe(false);
    expect(actualTables.has("host_releases")).toBe(false);
    expect(actualTables.has("v7_worker_scheduling")).toBe(false);
    expect(actualTables.has("v7_adapter_releases")).toBe(false);
    const inventoryColumns = new Set(
      database
        .prepare("PRAGMA table_info(workspace_worker_inventory)")
        .all()
        .map((row) => String((row as { name: string }).name)),
    );
    expect(
      [
        "activation_state",
        "readiness_state",
        "engine_version",
        "profile_definition_id",
        "profile_release_version",
        "provider_tool_name",
        "provider_tool_version",
      ].every((column) => inventoryColumns.has(column)),
    ).toBe(true);
    expect(
      [
        "name",
        "status",
        "auth_strategy",
        "credential_status",
        "default_model",
        "allowed_models_json",
        "adapter_version",
        "provider_tool_path",
      ].some((column) => inventoryColumns.has(column)),
    ).toBe(false);
    expect(inventoryColumns.has("worker_runtime_version")).toBe(false);
    const assignmentColumns = new Set(
      database
        .prepare("PRAGMA table_info(worker_assignments)")
        .all()
        .map((row) => String((row as { name: string }).name)),
    );
    expect(assignmentColumns.has("engine_version")).toBe(true);
    expect(assignmentColumns.has("worker_version")).toBe(false);

    const workspaceId = "workspace-schema-regression";
    const runtimeId = "runtime-schema-regression";
    const runtimeToken = "runtime-schema-regression-secret";
    database
      .prepare(
        `INSERT INTO users (id, email, display_name, created_at, updated_at)
         VALUES ('owner', 'owner@example.test', 'Owner', '2026-01-01', '2026-01-01')`,
      )
      .run();
    database
      .prepare(
        `INSERT INTO execution_workspaces (id, owner_user_id, name, created_at, updated_at)
         VALUES (?, 'owner', 'Schema Regression', '2026-01-01', '2026-01-01')`,
      )
      .run(workspaceId);
    database
      .prepare(
        `INSERT INTO workspace_runtime_identities
         (id, workspace_id, credential_key_ref, credential_token_hash, created_at)
         VALUES (?, ?, 'test-key-ref', ?, '2026-01-01')`,
      )
      .run(runtimeId, workspaceId, await hashToken(runtimeToken));

    class TestSocket {
      readyState = 1;
      attachment?: unknown;
      serializeAttachment(value: unknown) {
        this.attachment = value;
      }
      deserializeAttachment() {
        return this.attachment;
      }
      send() {}
      close() {}
    }
    class TestWebSocketPair {
      0 = new TestSocket();
      1 = new TestSocket();
    }
    class TestResponse {
      readonly status: number;
      readonly webSocket?: unknown;
      readonly value: unknown;
      constructor(
        body: unknown,
        init?: { status?: number; webSocket?: unknown },
      ) {
        this.status = init?.status ?? 200;
        this.webSocket = init?.webSocket;
        this.value = body;
      }
      static json(body: unknown, init?: { status?: number }) {
        return new TestResponse(body, init);
      }
    }
    vi.stubGlobal("WebSocketPair", TestWebSocketPair);
    vi.stubGlobal("Response", TestResponse);
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-09-27T10:00:00.000Z"));
    const logs: string[] = [];
    vi.spyOn(console, "error").mockImplementation((record) => {
      logs.push(String(record));
    });

    let acceptedSocket: TestSocket | undefined;
    const runtimeStorage = new Map<string, unknown>();
    const gateway = new WorkspaceGateway(
      {
        id: { name: workspaceId },
        storage: {
          get: async <T>(key: string) =>
            runtimeStorage.get(key) as T | undefined,
          put: async (key: string, value: unknown) => {
            runtimeStorage.set(key, value);
          },
          delete: async (key: string) => runtimeStorage.delete(key),
        },
        acceptWebSocket(socket: unknown) {
          acceptedSocket = socket as TestSocket;
        },
      } as never,
      { CONCLAVE_DB: new LocalD1(database) as never },
    );
    const response = (await gateway.fetch(
      new Request(
        `https://app.conclave.test/api/workspace-gateway/connect?workspaceRuntimeId=${runtimeId}`,
        {
          headers: {
            upgrade: "websocket",
            authorization: `Bearer ${runtimeToken}`,
          },
        },
      ),
    )) as unknown as TestResponse;

    expect(response.status).toBe(101);
    expect(acceptedSocket).toBeDefined();
    const sessionId = (acceptedSocket?.attachment as { sessionId: string })
      .sessionId;
    await waitFor(
      () =>
        database
          .prepare("SELECT 1 FROM workspace_sessions WHERE id = ?")
          .get(sessionId) !== undefined,
    );
    const initialSession = database
      .prepare("SELECT * FROM workspace_sessions WHERE id = ?")
      .get(sessionId) as {
      connected_at: string;
      last_heartbeat_at: string;
      disconnected_at: string | null;
      workspace_id: string;
      runtime_identity_id: string;
    };
    expect(initialSession).toMatchObject({
      workspace_id: workspaceId,
      runtime_identity_id: runtimeId,
      connected_at: "2026-09-27T10:00:00.000Z",
      last_heartbeat_at: "2026-09-27T10:00:00.000Z",
      disconnected_at: null,
    });

    vi.setSystemTime(new Date("2026-09-27T10:00:15.000Z"));
    gateway.webSocketMessage(
      acceptedSocket as unknown as WebSocket,
      JSON.stringify({
        protocol: "conclave.workspace-runtime-protocol",
        protocolVersion: "5.1",
        messageId: "heartbeat-schema-regression",
        timestamp: new Date().toISOString(),
        type: "workspace.heartbeat",
        executionWorkspaceId: workspaceId,
        workspaceRuntimeId: runtimeId,
        payload: {},
      }),
    );
    await waitFor(
      () =>
        (
          database
            .prepare(
              "SELECT last_heartbeat_at FROM workspace_sessions WHERE id = ?",
            )
            .get(sessionId) as { last_heartbeat_at: string }
        ).last_heartbeat_at === "2026-09-27T10:00:15.000Z",
    );

    vi.setSystemTime(new Date("2026-09-27T10:01:00.000Z"));
    gateway.webSocketClose(acceptedSocket as unknown as WebSocket);
    await waitFor(
      () =>
        (
          database
            .prepare(
              "SELECT disconnected_at FROM workspace_sessions WHERE id = ?",
            )
            .get(sessionId) as { disconnected_at: string | null }
        ).disconnected_at === "2026-09-27T10:01:00.000Z",
    );
    expect(
      (
        database
          .prepare("SELECT status FROM execution_workspaces WHERE id = ?")
          .get(workspaceId) as { status: string }
      ).status,
    ).toBe("offline");

    const failedWorkspaceId = "workspace-session-write-failure";
    const failedRuntimeId = "runtime-session-write-failure";
    const failedRuntimeToken = "runtime-session-write-failure-secret";
    database
      .prepare(
        `INSERT INTO execution_workspaces (id, owner_user_id, name, created_at, updated_at)
         VALUES (?, 'owner', 'Session Write Failure', '2026-01-01', '2026-01-01')`,
      )
      .run(failedWorkspaceId);
    database
      .prepare(
        `INSERT INTO workspace_runtime_identities
         (id, workspace_id, credential_key_ref, credential_token_hash, created_at)
         VALUES (?, ?, 'test-key-ref', ?, '2026-01-01')`,
      )
      .run(
        failedRuntimeId,
        failedWorkspaceId,
        await hashToken(failedRuntimeToken),
      );
    database.exec(`
      CREATE TRIGGER fail_workspace_online_projection
      BEFORE UPDATE OF status ON execution_workspaces
      WHEN NEW.status = 'online'
      BEGIN SELECT RAISE(FAIL, 'simulated online projection failure'); END;
    `);
    database.exec(`
      CREATE TRIGGER fail_session_insert
      BEFORE INSERT ON workspace_sessions
      BEGIN SELECT RAISE(FAIL, 'simulated session history write failure'); END;
    `);
    let failureSocket: TestSocket | undefined;
    const failureStorage = new Map<string, unknown>();
    const failureState = {
      id: { name: failedWorkspaceId },
      storage: {
        get: async <T>(key: string) => failureStorage.get(key) as T | undefined,
        put: async (key: string, value: unknown) => {
          failureStorage.set(key, value);
        },
        delete: async (key: string) => failureStorage.delete(key),
      },
      acceptWebSocket(socket: unknown) {
        failureSocket = socket as TestSocket;
      },
      getWebSockets() {
        return failureSocket ? [failureSocket as unknown as WebSocket] : [];
      },
    };
    const failureGateway = new WorkspaceGateway(failureState as never, {
      CONCLAVE_DB: new LocalD1(database) as never,
    });
    const failureResponse = (await failureGateway.fetch(
      new Request(
        `https://app.conclave.test/api/workspace-gateway/connect?workspaceRuntimeId=${failedRuntimeId}`,
        {
          headers: {
            upgrade: "websocket",
            authorization: `Bearer ${failedRuntimeToken}`,
          },
        },
      ),
    )) as unknown as TestResponse;
    expect(failureResponse.status).toBe(101);
    expect(failureSocket).toBeDefined();
    expect(
      (
        database
          .prepare("SELECT status FROM execution_workspaces WHERE id = ?")
          .get(failedWorkspaceId) as { status: string }
      ).status,
    ).toBe("enrolled");
    const rehydratedGateway = new WorkspaceGateway(failureState as never, {
      CONCLAVE_DB: new LocalD1(database) as never,
    });
    const liveStatus = (await rehydratedGateway.fetch(
      new Request("https://app.conclave.test/status"),
    )) as unknown as TestResponse;
    expect(liveStatus.value).toMatchObject({
      online: true,
      executionWorkspaceId: failedWorkspaceId,
      workspaceRuntimeId: failedRuntimeId,
    });
    await waitFor(() =>
      logs.some((entry) => entry.includes("GW-PROJECTION write_failed")),
    );
    expect(logs.join("\n")).not.toContain(failedRuntimeToken);

    database.close();
  });
});
