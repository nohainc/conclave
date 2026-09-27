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

  it("supports Gateway connect, heartbeat, and disconnect on migrations-v6 alone", async () => {
    const migrationDirectory = fileURLToPath(
      new URL("../migrations-v6/", import.meta.url),
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
      "v7_worker_scheduling",
      "workspace_pairing_intents",
      "workspace_project_grants",
      "workstream_execution_policies",
      "worker_assignments",
    ];
    const actualTables = new Set(
      database
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
        .all()
        .map((row) => String((row as { name: string }).name)),
    );
    expect(migrationFiles).toContain("0029_workspace_sessions.sql");
    expect(expectedTables.filter((table) => !actualTables.has(table))).toEqual(
      [],
    );

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
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-09-27T10:00:00.000Z"));

    let acceptedSocket: TestSocket | undefined;
    const gateway = new WorkspaceGateway(
      {
        id: { name: workspaceId },
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

    database.close();
  });
});
