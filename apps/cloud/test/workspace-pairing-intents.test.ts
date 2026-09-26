import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it } from "vitest";
import {
  handleCancelWorkspacePairingIntent,
  handleCreateWorkspacePairingIntent,
  handleGetWorkspacePairingIntent,
  handleRegenerateWorkspacePairingIntent,
  handleRedeemWorkspaceEnrollment,
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
          installationId: "install-test-1",
          name: "Test Computer",
          hostname: "test.local",
          platform: "macos",
          architecture: "arm64",
          appVersion: "1.0.0",
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
    ).toMatchObject({ installation_id: "install-test-1" });

    const duplicate = await handleRedeemWorkspaceEnrollment(
      new Request("https://conclave.test/api/workspace-runtime/enroll", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          token: pairing.token,
          installationId: "install-test-1",
          name: "Other",
        }),
      }),
      env,
    );
    expect(duplicate.status).toBe(401);
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS count FROM execution_workspaces")
        .get(),
    ).toMatchObject({ count: 1 });
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
