import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  handleCreateConfiguredWorker,
  handleGetConfiguredWorker,
  handleGetConfiguredWorkerWorkspaceCredential,
  handleListConfiguredWorkerWorkspaces,
  handleListWorkspaceWorkerInventory,
  handleV7WorkerScheduling,
  handleListV7Adapters,
  handlePublishV7Adapter,
  handleDownloadV7Adapter,
  handleRevokeV7Adapter,
  handleRevokeConfiguredWorkerWorkspaceCredential,
  handleRevokeConfiguredWorker,
  handleUpdateConfiguredWorkerWorkspaces,
} from "../src/routes/handlers.js";
import { WorkspaceGateway } from "../src/workspace-gateway.js";

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
  "0021_workspace_worker_inventory.sql",
  "0022_v7_adapter_releases.sql",
  "0023_workspace_runtime_credentials.sql",
  "0024_v7_worker_scheduling.sql",
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
  let ownedWorkspaceIds: string[] = [];
  const adapterObjects = new Map<string, Uint8Array>();
  const bucket = {
    async put(key: string, value: ArrayBuffer | ArrayBufferView | string) {
      const bytes =
        typeof value === "string"
          ? new TextEncoder().encode(value)
          : new Uint8Array(
              value instanceof ArrayBuffer
                ? value
                : value.buffer.slice(
                    value.byteOffset,
                    value.byteOffset + value.byteLength,
                  ),
            );
      adapterObjects.set(key, bytes);
      return { key };
    },
    async get(key: string) {
      const bytes = adapterObjects.get(key);
      return bytes
        ? {
            body: new Response(bytes.buffer as ArrayBuffer).body,
            size: bytes.byteLength,
            etag: "test-etag",
          }
        : null;
    },
    async delete(key: string) {
      adapterObjects.delete(key);
    },
  };
  const db = new LocalD1(sqlite);
  const env = {
    CONCLAVE_ENVIRONMENT: "development",
    CONCLAVE_DB: db,
    CONCLAVE_ARTIFACTS: bucket,
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
      ownedWorkspaceIds,
      ownedAccountIds: [],
    }),
  } as never;
  return {
    db,
    env,
    adapterObjects,
    setOwnedWorkspaceIds(workspaceIds: string[]) {
      ownedWorkspaceIds = workspaceIds;
    },
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
  it("reconciles authoritative inventory omission and reconnect idempotently", async () => {
    const test = createEnvironment();
    const gateway = new WorkspaceGateway(
      {} as never,
      { CONCLAVE_DB: test.db } as never,
    ) as unknown as {
      executionWorkspaceId: string | null;
      recordWorkerInventory(payload: unknown): Promise<void>;
    };
    gateway.executionWorkspaceId = "workspace-a";
    const worker = {
      workerId: "snapshot-worker",
      workerTypeId: "worker-type-codex",
      name: "Codex",
      status: "ready",
      revision: 1,
      localConcurrencyLimit: 2,
      credentialStatus: "ready",
    };
    await gateway.recordWorkerInventory({
      fullSnapshot: true,
      workers: [worker],
    });
    expect(
      test.db.sqlite
        .prepare(
          "SELECT status, revision FROM workspace_worker_inventory WHERE worker_id = 'snapshot-worker'",
        )
        .get(),
    ).toEqual({ status: "ready", revision: 1 });
    await gateway.recordWorkerInventory({ fullSnapshot: true, workers: [] });
    await gateway.recordWorkerInventory({ fullSnapshot: true, workers: [] });
    expect(
      test.db.sqlite
        .prepare(
          "SELECT status, removed_by_snapshot FROM workspace_worker_inventory WHERE worker_id = 'snapshot-worker'",
        )
        .get(),
    ).toEqual({ status: "removed", removed_by_snapshot: 1 });
    await gateway.recordWorkerInventory({
      fullSnapshot: true,
      workers: [worker],
    });
    expect(
      test.db.sqlite
        .prepare(
          "SELECT status, revision FROM workspace_worker_inventory WHERE worker_id = 'snapshot-worker'",
        )
        .get(),
    ).toEqual({ status: "ready", revision: 1 });
    await gateway.recordWorkerInventory({
      fullSnapshot: true,
      workers: [{ ...worker, revision: 2 }],
    });
    await gateway.recordWorkerInventory({
      fullSnapshot: true,
      workers: [{ ...worker, revision: 1, status: "needs_attention" }],
    });
    expect(
      test.db.sqlite
        .prepare(
          "SELECT status, revision FROM workspace_worker_inventory WHERE worker_id = 'snapshot-worker'",
        )
        .get(),
    ).toEqual({ status: "ready", revision: 2 });
    gateway.executionWorkspaceId = "workspace-b";
    await gateway.recordWorkerInventory({
      fullSnapshot: true,
      workers: [{ ...worker, revision: 99 }],
    });
    expect(
      test.db.sqlite
        .prepare(
          "SELECT workspace_id, revision FROM workspace_worker_inventory WHERE worker_id = 'snapshot-worker'",
        )
        .get(),
    ).toEqual({ workspace_id: "workspace-a", revision: 2 });
  });

  it("keeps Cloud scheduling separate and drains to disabled with an audit", async () => {
    const test = createEnvironment();
    test.db.sqlite.exec(`INSERT INTO workspace_worker_inventory
      (worker_id, workspace_id, owner_user_id, worker_type_id, name, status, auth_strategy,
       local_concurrency_limit, credential_status, revision, created_at, updated_at, last_seen_at)
      VALUES ('local-worker', 'workspace-a', 'owner', 'worker-type-codex', 'Codex', 'ready', 'browser_auth', 2, 'ready', 1, 'now', 'now', 'now');`);
    test.db.sqlite.exec(`
      INSERT INTO projects (id, owner_user_id, name, created_at, updated_at) VALUES ('project-a', 'owner', 'Project', 'now', 'now');
      INSERT INTO configured_workers (id, owner_user_id, name, worker_type_id, concurrency_limit, created_at, updated_at)
        VALUES ('local-worker', 'owner', 'Codex Local', 'worker-type-codex', 2, 'now', 'now');
      INSERT INTO workspace_runtime_identities (id, workspace_id, credential_key_ref, credential_token_hash, created_at)
        VALUES ('runtime-a', 'workspace-a', 'key-ref', 'token-hash', 'now');
      INSERT INTO worker_assignments (id, project_id, execution_workspace_id, runtime_identity_id, worker_id,
        configured_worker_id, status, created_at, updated_at)
        VALUES ('assignment-a', 'project-a', 'workspace-a', 'runtime-a', 'worker-type-codex', 'local-worker', 'running', 'now', 'now');
    `);
    const get = () =>
      handleV7WorkerScheduling(
        new Request(
          "https://conclave.test/api/v7/workers/local-worker/scheduling",
        ),
        test.env,
        "local-worker",
      );
    expect(((await (await get()).json()) as { state: string }).state).toBe(
      "disabled",
    );
    const enable = await handleV7WorkerScheduling(
      new Request(
        "https://conclave.test/api/v7/workers/local-worker/scheduling/enable",
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: "{}",
        },
      ),
      test.env,
      "local-worker",
      "enable",
    );
    expect(enable.status).toBe(200);
    expect(((await (await get()).json()) as { state: string }).state).toBe(
      "enabled",
    );
    const drain = await handleV7WorkerScheduling(
      new Request(
        "https://conclave.test/api/v7/workers/local-worker/scheduling/drain",
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: "{}",
        },
      ),
      test.env,
      "local-worker",
      "drain",
    );
    expect(((await drain.json()) as { state: string }).state).toBe("draining");
    expect(
      test.db.sqlite
        .prepare(
          "SELECT status FROM worker_assignments WHERE id = 'assignment-a'",
        )
        .get(),
    ).toEqual({ status: "running" });
    expect(((await (await get()).json()) as { state: string }).state).toBe(
      "draining",
    );
    test.db.sqlite
      .prepare(
        "UPDATE worker_assignments SET status = 'completed' WHERE id = 'assignment-a'",
      )
      .run();
    expect(((await (await get()).json()) as { state: string }).state).toBe(
      "disabled",
    );
    expect(
      test.db.sqlite
        .prepare(
          "SELECT action FROM v7_worker_scheduling_audit ORDER BY requested_at, action",
        )
        .all(),
    ).toEqual(
      expect.arrayContaining([
        { action: "enabled" },
        { action: "drain_requested" },
        { action: "drain_completed" },
      ]),
    );
  });

  it("cannot enable Cloud scheduling for a locally unready Worker", async () => {
    const test = createEnvironment();
    test.db.sqlite.exec(`INSERT INTO workspace_worker_inventory
      (worker_id, workspace_id, owner_user_id, worker_type_id, name, status, auth_strategy,
       local_concurrency_limit, credential_status, revision, created_at, updated_at, last_seen_at)
      VALUES ('unready-worker', 'workspace-a', 'owner', 'worker-type-codex', 'Codex', 'needs_attention', 'browser_auth', 1, 'ready', 1, 'now', 'now', 'now');`);
    await expect(
      handleV7WorkerScheduling(
        new Request(
          "https://conclave.test/api/v7/workers/unready-worker/scheduling/enable",
          {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: "{}",
          },
        ),
        test.env,
        "unready-worker",
        "enable",
      ),
    ).rejects.toMatchObject({ status: 409 });
    expect(
      test.db.sqlite
        .prepare(
          "SELECT state FROM v7_worker_scheduling WHERE worker_id = 'unready-worker'",
        )
        .get(),
    ).toBeUndefined();
  });

  it("lists safe local Worker inventory only for the signed-in owner", async () => {
    const test = createEnvironment();
    test.db.sqlite.exec(`
      INSERT INTO workspace_worker_inventory
        (worker_id, workspace_id, owner_user_id, worker_type_id, name, status,
         auth_strategy, default_model, allowed_models_json, capabilities_json,
         local_permissions_summary_json, local_concurrency_limit, adapter_version,
         credential_status, revision, created_at, updated_at, last_seen_at)
      VALUES ('local-worker-1', 'workspace-a', 'owner', 'worker-type-codex',
        'Codex Personal', 'ready', 'browser_auth', 'gpt-5.5', '["gpt-5.5"]',
        '["coding"]', '["workspace_files"]', 2, '1.2.0', 'ready', 3,
        'now', 'now', 'now');
      INSERT INTO workspace_worker_inventory
        (worker_id, workspace_id, owner_user_id, worker_type_id, name, status,
         auth_strategy, local_permissions_summary_json, local_concurrency_limit,
         credential_status, revision, created_at, updated_at, last_seen_at)
      VALUES ('other-worker-1', 'workspace-other', 'other', 'worker-type-codex',
        'Other Codex', 'ready', 'browser_auth', '[]', 1, 'ready', 1,
        'now', 'now', 'now');
    `);

    const response = await handleListWorkspaceWorkerInventory(
      new Request("https://conclave.test/api/v7/workers"),
      test.env,
    );
    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      workers: Array<Record<string, unknown>>;
    };
    expect(body.workers).toHaveLength(1);
    expect(body.workers[0]).toMatchObject({
      id: "local-worker-1",
      workspaceId: "workspace-a",
      status: "ready",
      localConcurrencyLimit: 2,
      capabilities: ["coding"],
    });
    expect(JSON.stringify(body)).not.toMatch(
      /credentialRef|secret|apiKey|path/i,
    );
  });

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

  it("publishes immutable signed V7 adapter releases and filters catalog by platform", async () => {
    const test = createEnvironment();
    const manifest = {
      workerTypeId: "codex",
      adapterVersion: "1.0.0",
      protocolVersion: "1.0",
      publisher: "conclave",
      displayName: "Codex",
      supportedPlatforms: ["linux-x64"],
      capabilities: ["code"],
      permissions: ["workspace:read", "shell:execute"],
      authStrategies: ["browser_auth"],
      modelSelectionMode: "allow_list",
      prerequisites: [],
      executable: "bin/adapter.mjs",
      launchArgs: [],
      secretRequirements: [],
      healthCheck: { mode: "protocol", timeoutMs: 5000 },
      packageDigest: "a".repeat(64),
      signature: "signed-package-digest",
      releaseChannel: "stable",
    };
    const archive = new TextEncoder().encode("fake-tarball-bytes");
    const publishRequest = (publishedManifest = manifest) =>
      new Request("https://conclave.test/api/v7/adapters/publish", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          manifest: publishedManifest,
          packageBase64: Buffer.from(archive).toString("base64"),
        }),
      });

    await expect(
      handlePublishV7Adapter(publishRequest(), test.env),
    ).rejects.toMatchObject({ status: 403 });
    test.setOwnedWorkspaceIds(["workspace-a"]);
    const published = await handlePublishV7Adapter(publishRequest(), test.env);
    expect(published.status).toBe(201);
    expect(await published.json()).toMatchObject({
      workerTypeId: "codex",
      version: "1.0.0",
      status: "published",
    });
    expect(test.adapterObjects.size).toBe(1);

    const catalog = await handleListV7Adapters(
      new Request(
        "https://conclave.test/api/v7/adapters?workerTypeId=codex&platform=linux-x64",
      ),
      test.env,
    );
    expect(
      ((await catalog.json()) as { releases: unknown[] }).releases,
    ).toHaveLength(1);
    const unsupportedPlatform = await handleListV7Adapters(
      new Request(
        "https://conclave.test/api/v7/adapters?workerTypeId=codex&platform=windows-x64",
      ),
      test.env,
    );
    expect(
      ((await unsupportedPlatform.json()) as { releases: unknown[] }).releases,
    ).toHaveLength(0);

    const downloaded = await handleDownloadV7Adapter(
      new Request(
        "https://conclave.test/api/v7/adapters/codex/versions/1.0.0/download",
      ),
      test.env,
      "codex",
      "1.0.0",
    );
    expect(downloaded.status).toBe(200);
    expect(downloaded.headers.get("x-conclave-package-digest")).toBe(
      "a".repeat(64),
    );
    expect(new Uint8Array(await downloaded.arrayBuffer())).toEqual(archive);

    const idempotent = await handlePublishV7Adapter(publishRequest(), test.env);
    expect(await idempotent.json()).toMatchObject({
      status: "already_published",
    });

    await expect(
      handlePublishV7Adapter(
        publishRequest({ ...manifest, signature: "different-signature" }),
        test.env,
      ),
    ).rejects.toMatchObject({ status: 409 });

    const revokeRequest = () =>
      new Request(
        "https://conclave.test/api/v7/adapters/codex/versions/1.0.0/revoke",
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ reason: "Publisher rotation" }),
        },
      );
    test.setUser("other");
    await expect(
      handleRevokeV7Adapter(revokeRequest(), test.env, "codex", "1.0.0"),
    ).rejects.toMatchObject({ status: 403 });
    test.setUser("owner");
    const revoked = await handleRevokeV7Adapter(
      revokeRequest(),
      test.env,
      "codex",
      "1.0.0",
    );
    expect(await revoked.json()).toMatchObject({ status: "revoked" });
    await expect(
      handleDownloadV7Adapter(
        new Request(
          "https://conclave.test/api/v7/adapters/codex/versions/1.0.0/download",
        ),
        test.env,
        "codex",
        "1.0.0",
      ),
    ).rejects.toMatchObject({ status: 410 });
  });
});
