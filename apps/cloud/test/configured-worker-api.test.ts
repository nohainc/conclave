import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  handleCreateConfiguredWorker,
  handleGetConfiguredWorker,
  handleGetConfiguredWorkerWorkspaceCredential,
  handleListConfiguredWorkerWorkspaces,
  handleRevokeConfiguredWorkerWorkspaceCredential,
  handleRevokeConfiguredWorker,
  handleUpdateConfiguredWorkerWorkspaces,
} from "../src/routes/handlers.js";

const migrationFiles = [
  "0001_conclave_v6.sql",
  "0002_workstream_integrations.sql",
  "0003_usage_audit_observability.sql",
  "0004_chat_workstream_mapping.sql",
  "0005_execution_foundation.sql",
  "0007_project_settings.sql",
  "0010_workspace_project_grant_policy.sql",
  "0011_project_invitations.sql",
  "0012_remove_project_repository.sql",
  "0013_configured_workers.sql",
  "0014_configured_worker_runtime_state.sql",
  "0015_configured_worker_assignments.sql",
  "0016_worker_first_execution_policy.sql",
  "0017_configured_worker_observability.sql",
  "0018_migrate_legacy_ai_accounts.sql",
  "0019_worker_assignment_requester.sql",
];

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

  async batch(statements: readonly LocalD1Statement[]): Promise<unknown[]> {
    this.sqlite.exec("BEGIN");
    try {
      const results: unknown[] = [];
      for (const statement of statements) results.push(await statement.run());
      this.sqlite.exec("COMMIT");
      return results;
    } catch (error) {
      this.sqlite.exec("ROLLBACK");
      throw error;
    }
  }
}

function createEnvironment() {
  const sqlite = new DatabaseSync(":memory:");
  sqlite.exec("PRAGMA foreign_keys = ON;");
  for (const file of migrationFiles) {
    sqlite.exec(
      readFileSync(
        fileURLToPath(new URL(`../migrations-v6/${file}`, import.meta.url)),
        "utf8",
      ),
    );
  }
  sqlite.exec(`
    INSERT INTO users VALUES ('owner', 'owner@example.test', 'Owner', 'active', 'now', 'now');
    INSERT INTO users VALUES ('other', 'other@example.test', 'Other', 'active', 'now', 'now');
    INSERT INTO execution_workspaces VALUES ('workspace-a', 'owner', 'Mac', 'online', 'now', 'now');
    INSERT INTO execution_workspaces VALUES ('workspace-b', 'owner', 'Linux', 'offline', 'now', 'now');
    INSERT INTO execution_workspaces VALUES ('workspace-other', 'other', 'Other', 'online', 'now', 'now');
    INSERT INTO workers VALUES ('worker-type-codex', 'Codex', 'active', 'now', 'now');
  `);

  let currentUserId = "owner";
  const db = new LocalD1(sqlite);
  const env = {
    CONCLAVE_ENVIRONMENT: "development",
    CONCLAVE_DB: db,
    TEST_AUTHENTICATION: async () => ({
      userId: currentUserId,
      user: {
        id: currentUserId,
        email: `${currentUserId}@example.test`,
        displayName: currentUserId,
        status: "active",
      },
      workspaceId: "",
      workspaceRole: "viewer",
      roles: ["viewer"],
      authorizedProjectIds: [],
      projectRoles: {},
      sessionId: `session-${currentUserId}`,
      clientType: "web",
      organizationId: "",
      organizationRoles: ["viewer"],
      authorizationModel: "v5",
      ownedWorkspaceIds: [],
      ownedAccountIds: [],
    }),
  } as never;
  return {
    db,
    env,
    setUser(userId: string) {
      currentUserId = userId;
    },
  };
}

function request(method: string, body?: Record<string, unknown>): Request {
  return new Request("https://conclave.test/api/workers", {
    method,
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

describe("configured Worker API", () => {
  it("creates a Worker with multiple owned Workspace bindings and readiness state", async () => {
    const test = createEnvironment();
    const response = await handleCreateConfiguredWorker(
      request("POST", {
        name: "Codex Personal",
        workerTypeId: "worker-type-codex",
        authStrategy: { authType: "oauth", sharingPolicy: "private_only" },
        defaultModel: "codex-latest",
        concurrencyLimit: 2,
        workspaceIds: ["workspace-a", "workspace-b"],
      }),
      test.env,
    );
    expect(response.status).toBe(201);
    const body = (await response.json()) as {
      worker: { id: string; workspaces: Array<Record<string, unknown>> };
    };
    expect(body.worker.workspaces).toHaveLength(2);
    expect(body.worker.workspaces[0]).toMatchObject({
      credentialStatus: "setup_required",
      nextActions: expect.arrayContaining(["setup_credentials"]),
    });
  });

  it("rejects duplicate names, invalid Worker Types, and foreign Workspaces", async () => {
    const test = createEnvironment();
    const body = {
      name: "Codex Personal",
      workerTypeId: "worker-type-codex",
      workspaceIds: [],
    };
    expect(
      (await handleCreateConfiguredWorker(request("POST", body), test.env))
        .status,
    ).toBe(201);
    await expect(
      handleCreateConfiguredWorker(request("POST", body), test.env),
    ).rejects.toMatchObject({ status: 409 });
    await expect(
      handleCreateConfiguredWorker(
        request("POST", {
          ...body,
          name: "Unknown",
          workerTypeId: "missing",
        }),
        test.env,
      ),
    ).rejects.toMatchObject({ status: 404 });
    await expect(
      handleCreateConfiguredWorker(
        request("POST", {
          ...body,
          name: "Foreign",
          workspaceIds: ["workspace-other"],
        }),
        test.env,
      ),
    ).rejects.toMatchObject({ status: 404 });
  });

  it("isolates ownership and supports replacing Workspace bindings", async () => {
    const test = createEnvironment();
    const created = await handleCreateConfiguredWorker(
      request("POST", {
        name: "Codex Personal",
        workerTypeId: "worker-type-codex",
        workspaceIds: ["workspace-a"],
      }),
      test.env,
    );
    const workerId = ((await created.json()) as { worker: { id: string } })
      .worker.id;
    test.setUser("other");
    await expect(
      handleGetConfiguredWorker(request("GET"), test.env, workerId),
    ).rejects.toMatchObject({ status: 404 });
    test.setUser("owner");
    const updated = await handleUpdateConfiguredWorkerWorkspaces(
      request("PUT", { workspaceIds: ["workspace-b"] }),
      test.env,
      workerId,
    );
    expect(updated.status).toBe(200);
    const workspaces = await handleListConfiguredWorkerWorkspaces(
      request("GET"),
      test.env,
      workerId,
    );
    expect(await workspaces.json()).toMatchObject({
      workspaces: [{ workspaceId: "workspace-b" }],
    });
  });

  it("revokes the Worker and disables all bindings", async () => {
    const test = createEnvironment();
    const created = await handleCreateConfiguredWorker(
      request("POST", {
        name: "Codex Personal",
        workerTypeId: "worker-type-codex",
        workspaceIds: ["workspace-a", "workspace-b"],
      }),
      test.env,
    );
    const workerId = ((await created.json()) as { worker: { id: string } })
      .worker.id;
    expect(
      (
        await handleRevokeConfiguredWorker(
          request("DELETE"),
          test.env,
          workerId,
        )
      ).status,
    ).toBe(200);
    const row = test.db.sqlite
      .prepare("SELECT status FROM configured_workers WHERE id = ?")
      .get(workerId) as { status: string };
    const bindings = test.db.sqlite
      .prepare(
        "SELECT enabled, local_readiness FROM worker_workspace_bindings WHERE worker_id = ? ORDER BY workspace_id",
      )
      .all(workerId) as Array<{ enabled: number; local_readiness: string }>;
    expect(row.status).toBe("revoked");
    expect(bindings).toEqual([
      { enabled: 0, local_readiness: "revoked" },
      { enabled: 0, local_readiness: "revoked" },
    ]);
    const auditActions = (
      await test.db
        .prepare(
          `SELECT action FROM configured_worker_audit_log WHERE configured_worker_id = ? ORDER BY created_at, action`,
        )
        .bind(workerId)
        .all<{ action: string }>()
    ).results.map((row) => row.action);
    expect(auditActions).toEqual(
      expect.arrayContaining([
        "worker.created",
        "worker.workspace.bound",
        "worker.revoked",
      ]),
    );
  });

  it("keeps credential readiness and revocation independent per Workspace", async () => {
    const test = createEnvironment();
    const created = await handleCreateConfiguredWorker(
      request("POST", {
        name: "Codex Contextual",
        workerTypeId: "worker-type-codex",
        authStrategy: {
          authType: "oauth",
          sharingPolicy: "private_only",
          providerMetadata: { provider: "example" },
        },
        workspaceIds: ["workspace-a", "workspace-b"],
      }),
      test.env,
    );
    const workerId = ((await created.json()) as { worker: { id: string } })
      .worker.id;
    await test.db
      .prepare(
        `UPDATE workspace_worker_credentials SET state = 'ready' WHERE worker_id = ? AND workspace_id = ?`,
      )
      .bind(workerId, "workspace-a")
      .run();
    await test.db
      .prepare(
        `UPDATE worker_workspace_bindings
            SET credential_status = 'ready', local_readiness = 'ready'
          WHERE worker_id = ? AND workspace_id = ?`,
      )
      .bind(workerId, "workspace-a")
      .run();

    const workspaceA = await handleGetConfiguredWorkerWorkspaceCredential(
      request("GET"),
      test.env,
      workerId,
      "workspace-a",
    );
    const workspaceABody = await workspaceA.json();
    expect(workspaceABody).toMatchObject({
      credential: {
        workerId,
        workspaceId: "workspace-a",
        state: "ready",
        credentialStatus: "ready",
      },
    });
    expect(JSON.stringify(workspaceABody)).not.toContain("localSecretRef");

    const workspaceB = await handleGetConfiguredWorkerWorkspaceCredential(
      request("GET"),
      test.env,
      workerId,
      "workspace-b",
    );
    expect(await workspaceB.json()).toMatchObject({
      credential: {
        state: "setup_required",
        credentialStatus: "setup_required",
      },
    });

    await handleRevokeConfiguredWorkerWorkspaceCredential(
      request("DELETE"),
      test.env,
      workerId,
      "workspace-a",
    );
    const states = (
      await test.db
        .prepare(
          `SELECT workspace_id, state FROM workspace_worker_credentials WHERE worker_id = ? ORDER BY workspace_id`,
        )
        .bind(workerId)
        .all<{ workspace_id: string; state: string }>()
    ).results;
    expect(states).toEqual([
      { workspace_id: "workspace-a", state: "revoked" },
      { workspace_id: "workspace-b", state: "setup_required" },
    ]);
    const auditActions = (
      await test.db
        .prepare(
          `SELECT action FROM configured_worker_audit_log WHERE configured_worker_id = ? ORDER BY created_at, action`,
        )
        .bind(workerId)
        .all<{ action: string }>()
    ).results.map((row) => row.action);
    expect(auditActions).toEqual(
      expect.arrayContaining(["worker.credential.revoked"]),
    );
  });
});
