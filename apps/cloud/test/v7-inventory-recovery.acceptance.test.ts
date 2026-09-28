import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { describe, expect, it } from "vitest";
import { WorkspaceGateway } from "../src/workspace-gateway.js";

class Statement {
  constructor(
    private readonly db: DatabaseSync,
    private readonly sql: string,
    private readonly values: unknown[] = [],
  ) {}
  bind(...values: unknown[]): Statement {
    return new Statement(this.db, this.sql, values);
  }
  async first<T>(): Promise<T | null> {
    return (
      (this.db.prepare(this.sql).get(...(this.values as SQLInputValue[])) as
        T | undefined) ?? null
    );
  }
  async run(): Promise<unknown> {
    return this.db.prepare(this.sql).run(...(this.values as SQLInputValue[]));
  }
  async all<T>(): Promise<{ results: T[] }> {
    return {
      results: this.db
        .prepare(this.sql)
        .all(...(this.values as SQLInputValue[])) as T[],
    };
  }
}

class LocalD1 {
  constructor(private readonly db: DatabaseSync) {}
  prepare(sql: string): Statement {
    return new Statement(this.db, sql);
  }
}

describe("V7 Workspace inventory recovery acceptance", () => {
  it("reconciles duplicate snapshots, omissions, reconnects, and foreign Worker IDs idempotently", async () => {
    const sqlite = new DatabaseSync(":memory:");
    sqlite.exec(`
      CREATE TABLE execution_workspaces (id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, name TEXT NOT NULL, status TEXT NOT NULL);
      CREATE TABLE workspace_worker_inventory (
        worker_id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, owner_user_id TEXT NOT NULL,
        worker_type_id TEXT NOT NULL, name TEXT NOT NULL, status TEXT NOT NULL,
        readiness_state TEXT NOT NULL DEFAULT 'test_failed',
        auth_strategy TEXT NOT NULL, default_model TEXT, allowed_models_json TEXT NOT NULL,
        capabilities_json TEXT NOT NULL, local_permissions_summary_json TEXT NOT NULL,
        local_concurrency_limit INTEGER NOT NULL, adapter_version TEXT, credential_status TEXT NOT NULL,
        revision INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        last_seen_at TEXT NOT NULL, removed_at TEXT, removed_by_snapshot INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE v7_worker_scheduling (worker_id TEXT PRIMARY KEY, state TEXT NOT NULL, updated_at TEXT NOT NULL);
      CREATE TABLE workspace_runtime_facts (
        workspace_id TEXT PRIMARY KEY, platform TEXT, architecture TEXT,
        hostname TEXT, app_version TEXT, runtime_capabilities_json TEXT,
        updated_at TEXT NOT NULL
      );
      INSERT INTO execution_workspaces VALUES ('workspace-a', 'owner-a', 'Development MacBook', 'online');
      INSERT INTO execution_workspaces VALUES ('workspace-b', 'owner-b', 'Other Workspace', 'online');
    `);
    const db = new LocalD1(sqlite);
    const gateway = new WorkspaceGateway(
      {} as never,
      { CONCLAVE_DB: db } as never,
    );
    const internal = gateway as unknown as {
      executionWorkspaceId: string;
      workspaceRuntimeId: string;
      correlationId: string;
      socket: { send(value: string): void };
      handleMessage(data: unknown, sessionId: string): Promise<void>;
      recordWorkerInventory(payload: unknown): Promise<void>;
    };
    const replies: string[] = [];
    internal.executionWorkspaceId = "workspace-a";
    internal.workspaceRuntimeId = "runtime-a";
    internal.correlationId = "inventory-recovery-ray";
    internal.socket = { send: (value) => replies.push(value) };
    const hello = {
      protocol: "conclave.workspace-runtime-protocol",
      protocolVersion: "5.1",
      messageId: "hello-duplicate",
      timestamp: "2026-09-26T00:00:00.000Z",
      type: "workspace.hello",
      executionWorkspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      payload: {
        platform: "macos",
        architecture: "arm64",
        hostname: "acceptance-host",
        appVersion: "7.0.0",
        capabilities: { v7Workers: true },
      },
    };
    await internal.handleMessage(hello, "session-a");
    await internal.handleMessage(hello, "session-a");
    expect(replies).toHaveLength(2);
    expect(
      sqlite
        .prepare(
          "SELECT hostname, app_version FROM workspace_runtime_facts WHERE workspace_id = ?",
        )
        .get("workspace-a"),
    ).toMatchObject({ hostname: "acceptance-host", app_version: "7.0.0" });
    expect(
      sqlite
        .prepare("SELECT name FROM execution_workspaces WHERE id = ?")
        .get("workspace-a"),
    ).toMatchObject({ name: "Development MacBook" });
    const report = {
      workerId: "worker-shared-id",
      workerTypeId: "fixture-worker",
      name: "Private Worker Name",
      status: "ready",
      readinessState: "ready",
      revision: 1,
      localConcurrencyLimit: 1,
      authStrategy: "api_key",
      credentialStatus: "ready",
      defaultModel: "private-model-choice",
      allowedModels: ["private-allow-list"],
      capabilities: ["code"],
      localPermissionsSummary: ["workspace:read"],
      createdAt: "2026-09-26T00:00:00.000Z",
      lastSeenAt: "2026-09-26T00:00:00.000Z",
    };

    internal.executionWorkspaceId = "workspace-a";
    await internal.recordWorkerInventory({
      fullSnapshot: true,
      workers: [report],
    });
    await internal.recordWorkerInventory({
      fullSnapshot: true,
      workers: [report],
    });
    let row = sqlite
      .prepare(
        "SELECT workspace_id, name, status, readiness_state, auth_strategy, default_model, allowed_models_json, local_permissions_summary_json, credential_status, revision, removed_by_snapshot FROM workspace_worker_inventory WHERE worker_id = ?",
      )
      .get("worker-shared-id") as Record<string, unknown>;
    expect(row).toMatchObject({
      workspace_id: "workspace-a",
      name: "fixture-worker",
      status: "ready",
      readiness_state: "ready",
      auth_strategy: "none",
      default_model: null,
      allowed_models_json: "[]",
      local_permissions_summary_json: "[]",
      credential_status: "not_required",
      revision: 1,
      removed_by_snapshot: 0,
    });

    await internal.recordWorkerInventory({
      fullSnapshot: false,
      workers: [
        {
          ...report,
          workerId: "worker-unready",
          name: "Unready Worker",
          readinessState: "unsupported_cli_version",
        },
      ],
    });
    expect(
      sqlite
        .prepare(
          "SELECT status, readiness_state FROM workspace_worker_inventory WHERE worker_id = ?",
        )
        .get("worker-unready"),
    ).toMatchObject({
      status: "needs_attention",
      readiness_state: "unsupported_cli_version",
    });

    await internal.recordWorkerInventory({ fullSnapshot: true, workers: [] });
    await internal.recordWorkerInventory({ fullSnapshot: true, workers: [] });
    row = sqlite
      .prepare(
        "SELECT workspace_id, status, revision, removed_by_snapshot FROM workspace_worker_inventory WHERE worker_id = ?",
      )
      .get("worker-shared-id") as Record<string, unknown>;
    expect(row).toMatchObject({
      workspace_id: "workspace-a",
      status: "removed",
      revision: 1,
      removed_by_snapshot: 1,
    });

    // A reconnect's equal-revision authoritative snapshot restores the local
    // projection without silently re-enabling Cloud scheduling.
    await internal.recordWorkerInventory({
      fullSnapshot: true,
      workers: [report],
    });
    row = sqlite
      .prepare(
        "SELECT status, revision, removed_by_snapshot FROM workspace_worker_inventory WHERE worker_id = ?",
      )
      .get("worker-shared-id") as Record<string, unknown>;
    expect(row).toMatchObject({
      status: "ready",
      revision: 1,
      removed_by_snapshot: 0,
    });
    expect(
      sqlite
        .prepare("SELECT state FROM v7_worker_scheduling WHERE worker_id = ?")
        .get("worker-shared-id"),
    ).toMatchObject({ state: "disabled" });

    internal.executionWorkspaceId = "workspace-b";
    await internal.recordWorkerInventory({
      fullSnapshot: true,
      workers: [{ ...report, revision: 99, name: "Foreign replacement" }],
    });
    row = sqlite
      .prepare(
        "SELECT workspace_id, name, revision FROM workspace_worker_inventory WHERE worker_id = ?",
      )
      .get("worker-shared-id") as Record<string, unknown>;
    expect(row).toMatchObject({
      workspace_id: "workspace-a",
      name: "fixture-worker",
      revision: 1,
    });

    internal.executionWorkspaceId = "workspace-a";
    await internal.recordWorkerInventory({
      fullSnapshot: true,
      workers: [{ ...report, revision: Number.NaN, name: "Malformed" }],
    });
    row = sqlite
      .prepare(
        "SELECT status, revision FROM workspace_worker_inventory WHERE worker_id = ?",
      )
      .get("worker-shared-id") as Record<string, unknown>;
    expect(row).toMatchObject({ status: "removed", revision: 1 });
    sqlite.close();
  });
});
