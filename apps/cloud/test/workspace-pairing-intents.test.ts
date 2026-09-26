import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import {
  handleCancelWorkspacePairingIntent,
  handleCreateWorkspace,
  handleCreateWorkspacePairingIntent,
  handleGetWorkspacePairingIntent,
  handleRegenerateWorkspacePairingIntent,
  handleRedeemWorkspaceEnrollment,
  handleUpdateWorkspace,
} from "../src/routes/handlers.js";

const migrationsDirectory = fileURLToPath(
  new URL("../migrations-v6/", import.meta.url),
);

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

  async run(): Promise<{
    success: true;
    meta: { changes: number; last_row_id: number };
  }> {
    const result = this.db
      .prepare(this.sql)
      .run(...(this.values as SQLInputValue[]));
    return {
      success: true,
      meta: {
        changes: Number(result.changes),
        last_row_id: Number(result.lastInsertRowid),
      },
    };
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
      const results = [];
      for (const statement of statements) results.push(await statement.run());
      this.sqlite.exec("COMMIT");
      return results;
    } catch (error) {
      this.sqlite.exec("ROLLBACK");
      throw error;
    }
  }
}

const ownerContext = (userId: string) => ({
  userId,
  user: {
    id: userId,
    email: `${userId}@example.test`,
    displayName: userId,
    status: "active" as const,
  },
  workspaceId: "",
  workspaceRole: "viewer" as const,
  roles: ["viewer" as const],
  authorizedProjectIds: [],
  projectRoles: {},
  sessionId: `session-${userId}`,
  clientType: "web" as const,
  organizationId: "",
  organizationRoles: ["viewer" as const],
  authorizationModel: "v5" as const,
  ownedWorkspaceIds: [],
  ownedAccountIds: [],
});

describe("Workspace pairing intents", () => {
  const databases: DatabaseSync[] = [];
  afterEach(() => {
    for (const database of databases.splice(0)) database.close();
  });

  function setup() {
    const sqlite = new DatabaseSync(":memory:");
    sqlite.exec("PRAGMA foreign_keys = ON");
    for (const filename of fs.readdirSync(migrationsDirectory).sort()) {
      if (filename.endsWith(".sql")) {
        sqlite.exec(
          fs.readFileSync(path.join(migrationsDirectory, filename), "utf8"),
        );
      }
    }
    sqlite.exec(`
      INSERT INTO users (id, email, display_name, status, created_at, updated_at)
      VALUES ('owner', 'owner@example.test', 'Owner', 'active', 'now', 'now');
      INSERT INTO users (id, email, display_name, status, created_at, updated_at)
      VALUES ('other', 'other@example.test', 'Other', 'active', 'now', 'now');
    `);
    databases.push(sqlite);
    const db = new LocalD1(sqlite);
    const env = {
      CONCLAVE_ENVIRONMENT: "development",
      CONCLAVE_DB: db,
      TEST_AUTHENTICATION: async (request: Request) =>
        ownerContext(request.headers.get("x-test-user") ?? "owner"),
    } as never;
    return { sqlite, db, env };
  }

  it("renames the canonical execution Workspace without changing its runtime identity", async () => {
    const { sqlite, env } = setup();
    sqlite.exec(`
      INSERT INTO execution_workspaces
        (id, owner_user_id, name, status, created_at, updated_at)
        VALUES ('ws-rename', 'owner', 'Development MacBook', 'offline', 'now', 'now');
      INSERT INTO workspace_runtime_identities
        (id, workspace_id, credential_key_ref, credential_token_hash, created_at, revoked_at)
        VALUES ('runtime-rename', 'ws-rename', 'runtime-key', 'sha256:saved-token', 'now', NULL);
      INSERT INTO workspace_runtime_facts
        (workspace_id, platform, architecture, hostname, app_version, runtime_capabilities_json, updated_at)
        VALUES ('ws-rename', 'macos', 'arm64', 'Vitaliis-MacBook-Pro.local', '1.4.2', '{}', 'now');
    `);

    const response = await handleUpdateWorkspace(
      new Request("https://conclave.test/api/workspaces/ws-rename", {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "Dev Lab" }),
      }),
      env,
      "ws-rename",
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      workspace: { id: "ws-rename", name: "Dev Lab" },
    });
    expect(
      sqlite
        .prepare("SELECT name FROM execution_workspaces WHERE id = ?")
        .get("ws-rename"),
    ).toMatchObject({ name: "Dev Lab" });
    expect(
      sqlite
        .prepare(
          "SELECT credential_token_hash FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-rename"),
    ).toMatchObject({ credential_token_hash: "sha256:saved-token" });
    expect(
      sqlite
        .prepare(
          "SELECT hostname FROM workspace_runtime_facts WHERE workspace_id = ?",
        )
        .get("ws-rename"),
    ).toMatchObject({ hostname: "Vitaliis-MacBook-Pro.local" });
  });

  it("requires pairing before creating a V7 execution Workspace", async () => {
    const { sqlite, env } = setup();
    await expect(
      handleCreateWorkspace(
        new Request("https://conclave.test/api/workspaces", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ name: "Unpaired placeholder" }),
        }),
        env,
      ),
    ).rejects.toThrow("before pairing is no longer supported");
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS count FROM execution_workspaces")
        .get(),
    ).toMatchObject({ count: 0 });
  });

  it("creates a hashed, owner-scoped intent without a permanent Workspace", async () => {
    const { sqlite, env } = setup();
    const response = await handleCreateWorkspacePairingIntent(
      new Request("https://conclave.test/api/workspace-pairing-intents", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({}),
      }),
      env,
    );
    const result = (await response.json()) as {
      id: string;
      token: string;
      status: string;
      expiresAt: string;
    };

    expect(response.status).toBe(201);
    expect(result.token).toMatch(/^conclave_pair_[a-f0-9]{32}$/);
    expect(result.status).toBe("pending");
    expect(Date.parse(result.expiresAt) - Date.now()).toBeLessThanOrEqual(
      15 * 60_000,
    );
    expect(
      sqlite
        .prepare(
          "SELECT token_hash FROM workspace_pairing_intents WHERE pairing_id = ?",
        )
        .get(result.id),
    ).not.toEqual({ token_hash: result.token });
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS count FROM execution_workspaces")
        .get(),
    ).toEqual({ count: 0 });
  });

  it("atomically creates the Workspace and runtime when the desktop claims it", async () => {
    const { sqlite, env } = setup();
    const created = await handleCreateWorkspacePairingIntent(
      new Request("https://conclave.test/api/workspace-pairing-intents", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
      }),
      env,
    );
    const pairing = (await created.json()) as { token: string };

    const claim = await handleRedeemWorkspaceEnrollment(
      new Request("https://conclave.test/api/workspace-runtime/enroll", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          token: pairing.token,
          installationId: "install_12345678-1234-4234-8234-123456789abc",
          name: "Test Computer",
          hostname: "test.local",
          platform: "macos",
          architecture: "arm64",
          appVersion: "1.0.0",
          runtimeCapabilities: {
            os: "macos",
            arch: "arm64",
            appVersion: "1.0.0",
            supportedRuntimes: ["dart"],
            maxConcurrentWorkers: 1,
          },
        }),
      }),
      env,
    );
    const claimed = (await claim.json()) as {
      workspaceId: string;
      workspaceRuntimeId: string;
      authToken: string;
    };
    expect(claim.status).toBe(201);
    expect(claimed.authToken).toContain("conclave_workspace_tok_");
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS count FROM execution_workspaces")
        .get(),
    ).toMatchObject({ count: 1 });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id FROM workspace_runtime_identities WHERE id = ?",
        )
        .get(claimed.workspaceRuntimeId),
    ).toMatchObject({
      installation_id: "install_12345678-1234-4234-8234-123456789abc",
    });
    expect(
      sqlite
        .prepare(
          "SELECT hostname, platform, architecture, app_version FROM workspace_runtime_facts WHERE workspace_id = ?",
        )
        .get(claimed.workspaceId),
    ).toMatchObject({
      hostname: "test.local",
      platform: "macos",
      architecture: "arm64",
      app_version: "1.0.0",
    });
    expect(
      sqlite
        .prepare(
          "SELECT COUNT(*) AS count FROM workspace_audit_log WHERE workspace_id = ?",
        )
        .get(claimed.workspaceId),
    ).toMatchObject({ count: 2 });

    const duplicate = await handleRedeemWorkspaceEnrollment(
      new Request("https://conclave.test/api/workspace-runtime/enroll", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          token: pairing.token,
          installationId: "install_12345678-1234-4234-8234-123456789abc",
          name: "Other",
        }),
      }),
      env,
    );
    expect(duplicate.status).toBe(409);
    expect(await duplicate.json()).toMatchObject({
      code: "pairing_already_claimed",
      workspaceId: claimed.workspaceId,
    });
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS count FROM execution_workspaces")
        .get(),
    ).toMatchObject({ count: 1 });

    const anotherIntent = await handleCreateWorkspacePairingIntent(
      new Request("https://conclave.test/api/workspace-pairing-intents", {
        method: "POST",
        body: "{}",
      }),
      env,
    );
    const secondPairing = (await anotherIntent.json()) as { token: string };
    const alreadyPaired = await handleRedeemWorkspaceEnrollment(
      new Request("https://conclave.test/api/workspace-runtime/enroll", {
        method: "POST",
        body: JSON.stringify({
          token: secondPairing.token,
          installationId: "install_12345678-1234-4234-8234-123456789abc",
        }),
      }),
      env,
    );
    expect(alreadyPaired.status).toBe(409);
    expect(await alreadyPaired.json()).toMatchObject({
      code: "installation_already_paired",
      workspaceId: claimed.workspaceId,
    });
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS count FROM execution_workspaces")
        .get(),
    ).toMatchObject({ count: 1 });
  });

  it("rejects invalid machine metadata without consuming the intent", async () => {
    const { sqlite, env } = setup();
    const created = await handleCreateWorkspacePairingIntent(
      new Request("https://conclave.test/api/workspace-pairing-intents", {
        method: "POST",
        body: "{}",
      }),
      env,
    );
    const pairing = (await created.json()) as { token: string; id: string };
    const response = await handleRedeemWorkspaceEnrollment(
      new Request("https://conclave.test/api/workspace-runtime/enroll", {
        method: "POST",
        body: JSON.stringify({
          token: pairing.token,
          installationId: "bad-id",
        }),
      }),
      env,
    );
    expect(response.status).toBe(400);
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS count FROM execution_workspaces")
        .get(),
    ).toMatchObject({ count: 0 });
    expect(
      sqlite
        .prepare(
          "SELECT used_at FROM workspace_pairing_intents WHERE pairing_id = ?",
        )
        .get(pairing.id),
    ).toMatchObject({ used_at: null });
  });

  it("rejects a suspended owner before creating any Workspace", async () => {
    const { sqlite, env } = setup();
    const created = await handleCreateWorkspacePairingIntent(
      new Request("https://conclave.test/api/workspace-pairing-intents", {
        method: "POST",
        body: "{}",
      }),
      env,
    );
    const pairing = (await created.json()) as { token: string };
    sqlite
      .prepare("UPDATE users SET status = 'suspended' WHERE id = 'owner'")
      .run();
    const response = await handleRedeemWorkspaceEnrollment(
      new Request("https://conclave.test/api/workspace-runtime/enroll", {
        method: "POST",
        body: JSON.stringify({ token: pairing.token }),
      }),
      env,
    );
    expect(response.status).toBe(403);
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS count FROM execution_workspaces")
        .get(),
    ).toMatchObject({ count: 0 });
  });

  it("requires explicit recovery after revocation and permits a new account only after that policy", async () => {
    const { sqlite, env } = setup();
    const firstIntent = await handleCreateWorkspacePairingIntent(
      new Request("https://conclave.test/api/workspace-pairing-intents", {
        method: "POST",
        body: "{}",
      }),
      env,
    );
    const firstCode = (await firstIntent.json()) as { token: string };
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    const capabilities = {
      os: "macos",
      arch: "arm64",
      appVersion: "1.0.0",
      supportedRuntimes: ["dart"],
      maxConcurrentWorkers: 1,
    };
    const claimRequest = (token: string, allowRecovery = false) =>
      new Request("https://conclave.test/api/workspace-runtime/enroll", {
        method: "POST",
        body: JSON.stringify({
          token,
          installationId,
          name: "Test Computer",
          hostname: "test.local",
          platform: "macos",
          architecture: "arm64",
          appVersion: "1.0.0",
          runtimeCapabilities: capabilities,
          allowRecovery,
        }),
      });
    const firstClaim = await handleRedeemWorkspaceEnrollment(
      claimRequest(firstCode.token),
      env,
    );
    const original = (await firstClaim.json()) as { workspaceId: string };
    expect(firstClaim.status).toBe(201);

    const copiedIntent = await handleCreateWorkspacePairingIntent(
      new Request("https://conclave.test/api/workspace-pairing-intents", {
        method: "POST",
        headers: { "x-test-user": "other" },
        body: "{}",
      }),
      env,
    );
    const copiedCode = (await copiedIntent.json()) as { token: string };
    const copiedClaim = await handleRedeemWorkspaceEnrollment(
      claimRequest(copiedCode.token, true),
      env,
    );
    expect(copiedClaim.status).toBe(409);
    expect(await copiedClaim.json()).toMatchObject({
      code: "installation_already_paired",
      workspaceId: original.workspaceId,
    });

    sqlite
      .prepare(
        "UPDATE execution_workspaces SET status = 'revoked' WHERE id = ?",
      )
      .run(original.workspaceId);
    sqlite
      .prepare(
        "UPDATE workspace_runtime_identities SET revoked_at = 'now' WHERE workspace_id = ?",
      )
      .run(original.workspaceId);

    const recoveryRequired = await handleRedeemWorkspaceEnrollment(
      claimRequest(copiedCode.token),
      env,
    );
    expect(recoveryRequired.status).toBe(409);
    expect(await recoveryRequired.json()).toMatchObject({
      code: "installation_recovery_required",
    });
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS count FROM execution_workspaces")
        .get(),
    ).toMatchObject({ count: 1 });

    const recovered = await handleRedeemWorkspaceEnrollment(
      claimRequest(copiedCode.token, true),
      env,
    );
    expect(recovered.status).toBe(201);
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS count FROM execution_workspaces")
        .get(),
    ).toMatchObject({ count: 2 });
  });

  it("rolls back the Workspace and intent claim if any transaction write fails", async () => {
    const { sqlite, env } = setup();
    const created = await handleCreateWorkspacePairingIntent(
      new Request("https://conclave.test/api/workspace-pairing-intents", {
        method: "POST",
        body: "{}",
      }),
      env,
    );
    const pairing = (await created.json()) as { token: string; id: string };
    sqlite.exec(`
      CREATE TRIGGER fail_pairing_audit
      BEFORE INSERT ON workspace_audit_log
      WHEN NEW.action = 'workspace.runtime.paired'
      BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END;
    `);
    await expect(
      handleRedeemWorkspaceEnrollment(
        new Request("https://conclave.test/api/workspace-runtime/enroll", {
          method: "POST",
          body: JSON.stringify({
            token: pairing.token,
            installationId: "install_12345678-1234-4234-8234-123456789abc",
            name: "Test Computer",
            hostname: "test.local",
            platform: "macos",
            architecture: "arm64",
            appVersion: "1.0.0",
            runtimeCapabilities: {
              os: "macos",
              arch: "arm64",
              appVersion: "1.0.0",
              supportedRuntimes: ["dart"],
              maxConcurrentWorkers: 1,
            },
          }),
        }),
        env,
      ),
    ).rejects.toThrow("injected audit failure");
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS count FROM execution_workspaces")
        .get(),
    ).toMatchObject({ count: 0 });
    expect(
      sqlite
        .prepare(
          "SELECT used_at FROM workspace_pairing_intents WHERE pairing_id = ?",
        )
        .get(pairing.id),
    ).toMatchObject({ used_at: null });
  });

  it("returns status only to its owner, and supports cancellation and regeneration", async () => {
    const { sqlite, env } = setup();
    const created = await handleCreateWorkspacePairingIntent(
      new Request("https://conclave.test/api/workspace-pairing-intents", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
      }),
      env,
    );
    const intent = (await created.json()) as { id: string; token: string };

    const status = await handleGetWorkspacePairingIntent(
      new Request("https://conclave.test/api/workspace-pairing-intents"),
      env,
      intent.id,
    );
    const statusBody = (await status.json()) as {
      pairingIntent: Record<string, unknown>;
    };
    expect(statusBody.pairingIntent.status).toBe("pending");
    expect(statusBody.pairingIntent).not.toHaveProperty("token");

    await expect(
      handleGetWorkspacePairingIntent(
        new Request("https://conclave.test/api/workspace-pairing-intents", {
          headers: { "x-test-user": "other" },
        }),
        env,
        intent.id,
      ),
    ).rejects.toMatchObject({ status: 404 });

    const regenerated = await handleRegenerateWorkspacePairingIntent(
      new Request("https://conclave.test/api/workspace-pairing-intents", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
      }),
      env,
      intent.id,
    );
    const replacement = (await regenerated.json()) as {
      id: string;
      token: string;
    };
    expect(regenerated.status).toBe(201);
    expect(replacement.id).not.toBe(intent.id);
    expect(replacement.token).not.toBe(intent.token);

    const oldStatus = await handleGetWorkspacePairingIntent(
      new Request("https://conclave.test/api/workspace-pairing-intents"),
      env,
      intent.id,
    );
    expect(
      ((await oldStatus.json()) as { pairingIntent: { status: string } })
        .pairingIntent.status,
    ).toBe("cancelled");

    const cancelled = await handleCancelWorkspacePairingIntent(
      new Request("https://conclave.test/api/workspace-pairing-intents", {
        method: "POST",
      }),
      env,
      replacement.id,
    );
    expect(cancelled.status).toBe(200);
    const finalStatus = await handleGetWorkspacePairingIntent(
      new Request("https://conclave.test/api/workspace-pairing-intents"),
      env,
      replacement.id,
    );
    expect(
      ((await finalStatus.json()) as { pairingIntent: { status: string } })
        .pairingIntent.status,
    ).toBe("cancelled");
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS count FROM execution_workspaces")
        .get(),
    ).toEqual({ count: 0 });
  });
});
