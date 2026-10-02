import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";
import { hashToken } from "../../../packages/security/src/index.js";
import { identityService } from "../src/auth/index.js";
import {
  handleApproveDesktopAuthIntent,
  handleClaimDesktopAuthIntent,
  handleCreateDesktopAuthIntent,
  handleDesktopAuthIntentStatus,
  handleDesktopAuthIntentBrowserStatus,
  handleCancelDesktopAuthIntent,
  handleDenyDesktopAuthIntent,
  handleGetDesktopHumanSession,
  handleCheckWorkspaceOwnership,
  handleDisconnectDesktopWorkspace,
  handleReleaseDesktopWorkspace,
  handleRegisterWorkspaceFromDesktop,
  handleRevokeDesktopHumanSession,
  handleRotateDesktopHumanSession,
} from "../src/routes/handlers.js";

const migrationsDirectory = fileURLToPath(
  new URL("../migrations-v8/", import.meta.url),
);

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
  async all<T>(): Promise<{ results: T[] }> {
    return {
      results: this.db
        .prepare(this.sql)
        .all(...(this.values as SQLInputValue[])) as T[],
    };
  }
  async run(): Promise<{ meta: { changes: number } }> {
    const result = this.db
      .prepare(this.sql)
      .run(...(this.values as SQLInputValue[]));
    return { meta: { changes: Number(result.changes) } };
  }
}
class TestD1 {
  constructor(readonly sqlite: DatabaseSync) {}
  prepare(sql: string): Statement {
    return new Statement(this.sqlite, sql);
  }
  async batch(statements: readonly Statement[]): Promise<unknown[]> {
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

describe("desktop human authentication", () => {
  const databases: DatabaseSync[] = [];
  afterEach(() => {
    vi.restoreAllMocks();
    for (const database of databases.splice(0)) database.close();
  });

  async function setup() {
    const sqlite = new DatabaseSync(":memory:");
    sqlite.exec("PRAGMA foreign_keys = ON");
    databases.push(sqlite);
    for (const filename of fs.readdirSync(migrationsDirectory).sort()) {
      if (filename.endsWith(".sql"))
        sqlite.exec(
          fs.readFileSync(path.join(migrationsDirectory, filename), "utf8"),
        );
    }
    const db = new TestD1(sqlite);
    const env = {
      CONCLAVE_DB: db,
      CONCLAVE_WORKSPACE_GATEWAY: {
        getByName: () => ({
          fetch: async () => Response.json({ online: false }),
        }),
      },
    } as never;
    vi.spyOn(identityService, "resolve").mockResolvedValue({
      userId: "human-1",
      email: "person@example.test",
      name: "Person",
      sessionId: "browser-session-1",
    });
    return { db, env, sqlite };
  }

  it("exchanges a browser-approved 1.1 intent without a comparison code for an independently revocable desktop session", async () => {
    const { env, sqlite } = await setup();
    const create = await handleCreateDesktopAuthIntent(
      new Request("https://app.conclave.test/api/desktop-auth/intents", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          clientName: "Conclave Workspace",
          contractVersion: "1.1",
        }),
      }),
      env,
    );
    expect(create.status).toBe(201);
    const intent = (await create.json()) as {
      intentId: string;
      userCode?: string;
      pollToken: string;
      verificationUrl: string;
    };
    expect(new URL(intent.verificationUrl).pathname).toBe(
      "/desktop-auth/approve",
    );
    expect(intent.userCode).toBeUndefined();

    const pending = await handleDesktopAuthIntentStatus(
      new Request(
        `https://app.conclave.test/api/desktop-auth/intents/${intent.intentId}`,
        {
          headers: { authorization: `Bearer ${intent.pollToken}` },
        },
      ),
      env,
      intent.intentId,
    );
    expect(((await pending.json()) as { status: string }).status).toBe(
      "pending",
    );

    const approval = await handleApproveDesktopAuthIntent(
      new Request("https://app.conclave.test/api/desktop-auth/approve", {
        method: "POST",
        headers: {
          cookie: "better-auth-session=opaque",
          "content-type": "application/json",
        },
        body: JSON.stringify({}),
      }),
      env,
      intent.intentId,
    );
    expect(approval.status).toBe(200);

    const claim = await handleClaimDesktopAuthIntent(
      new Request("https://app.conclave.test/api/desktop-auth/claim", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ pollToken: intent.pollToken }),
      }),
      env,
      intent.intentId,
    );
    const session = (await claim.json()) as {
      credential: string;
      sessionId: string;
      audience: string;
      user: { email: string };
    };
    expect(session.audience).toBe("conclave.desktop.management");
    expect(session.user.email).toBe("person@example.test");
    expect(session.credential).toMatch(/^conclave_dhs_/);
    const savedHash = sqlite
      .prepare("SELECT token_hash FROM desktop_human_sessions")
      .get() as { token_hash: string };
    expect(savedHash.token_hash).toBe(await hashToken(session.credential));

    const duplicateClaim = await handleClaimDesktopAuthIntent(
      new Request("https://app.conclave.test/api/desktop-auth/claim", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ pollToken: intent.pollToken }),
      }),
      env,
      intent.intentId,
    ).then(
      () => null,
      (error: Error) => error,
    );
    expect(duplicateClaim?.message).toMatch(/already claimed/);

    const humanSession = await handleGetDesktopHumanSession(
      new Request("https://app.conclave.test/api/desktop-auth/session", {
        headers: { authorization: `Bearer ${session.credential}` },
      }),
      env,
    );
    expect(
      ((await humanSession.json()) as { user: { userId: string } }).user.userId,
    ).toBe("human-1");

    await expect(
      handleGetDesktopHumanSession(
        new Request("https://app.conclave.test/api/desktop-auth/session", {
          headers: { authorization: "Bearer conclave_workspace_tok_runtime" },
        }),
        env,
      ),
    ).rejects.toThrow(/invalid, expired, or revoked/);

    const revoked = await handleRevokeDesktopHumanSession(
      new Request(
        `https://app.conclave.test/api/desktop-auth/sessions/${session.sessionId}/revoke`,
        {
          method: "POST",
          headers: { authorization: `Bearer ${session.credential}` },
        },
      ),
      env,
      session.sessionId,
    );
    expect(((await revoked.json()) as { revoked: boolean }).revoked).toBe(true);
    await expect(
      handleGetDesktopHumanSession(
        new Request("https://app.conclave.test/api/desktop-auth/session", {
          headers: { authorization: `Bearer ${session.credential}` },
        }),
        env,
      ),
    ).rejects.toThrow(/invalid, expired, or revoked/);
  });

  it("lets only the intent poll credential cancel and expose terminal browser status", async () => {
    const { env } = await setup();
    const create = await handleCreateDesktopAuthIntent(
      new Request("https://app.conclave.test/api/desktop-auth/intents", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          clientName: "Conclave Workspace",
          contractVersion: "1.1",
        }),
      }),
      env,
    );
    const intent = (await create.json()) as {
      intentId: string;
      pollToken: string;
    };
    await expect(
      handleCancelDesktopAuthIntent(
        new Request("https://app.conclave.test/cancel", { method: "POST" }),
        env,
        intent.intentId,
      ),
    ).rejects.toThrow(/credential required/);

    const canceled = await handleCancelDesktopAuthIntent(
      new Request("https://app.conclave.test/cancel", {
        method: "POST",
        headers: { authorization: `Bearer ${intent.pollToken}` },
      }),
      env,
      intent.intentId,
    );
    expect(canceled.status).toBe(200);
    const status = await handleDesktopAuthIntentBrowserStatus(
      new Request(
        `https://app.conclave.test/api/desktop-auth/intents/${intent.intentId}/browser-status`,
      ),
      env,
      intent.intentId,
    );
    expect(((await status.json()) as { status: string }).status).toBe("denied");
  });

  it("allows an authenticated browser user to cancel a pending intent", async () => {
    const { env } = await setup();
    const create = await handleCreateDesktopAuthIntent(
      new Request("https://app.conclave.test/api/desktop-auth/intents", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          clientName: "Workspace",
          contractVersion: "1.1",
        }),
      }),
      env,
    );
    const intent = (await create.json()) as { intentId: string };
    const response = await handleDenyDesktopAuthIntent(
      new Request("https://app.conclave.test/cancel", {
        method: "POST",
        headers: { cookie: "better-auth-session=opaque" },
      }),
      env,
      intent.intentId,
    );
    expect(response.status).toBe(200);
    const status = await handleDesktopAuthIntentBrowserStatus(
      new Request("https://app.conclave.test/status"),
      env,
      intent.intentId,
    );
    expect(((await status.json()) as { status: string }).status).toBe("denied");
  });

  it("keeps runtime credentials out of human management APIs", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-a", "a@example.test", "A", now, now);
    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'offline', ?, ?)",
      )
      .run("workspace-a", "human-a", "A's Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_key_ref, credential_token_hash, created_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run(
        "runtime-a",
        "workspace-a",
        "runtime-key",
        await hashToken("runtime-only-secret"),
        now,
      );

    await expect(
      handleGetDesktopHumanSession(
        new Request("https://app.conclave.test/api/desktop-auth/session", {
          headers: { authorization: "Bearer runtime-only-secret" },
        }),
        env,
      ),
    ).rejects.toMatchObject({
      status: 401,
      message: "Desktop human session is invalid, expired, or revoked",
    });
  });

  it("allows ownership transition only after explicit release", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    const accounts = [
      ["human-a", "a@example.test"],
      ["human-b", "b@example.test"],
    ] as const;
    for (const [id, email] of accounts) {
      sqlite
        .prepare(
          "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        )
        .run(id, email, id, now, now);
      sqlite
        .prepare(
          "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .run(
          `session-${id}`,
          id,
          await hashToken(`${id}-secret`),
          "conclave.desktop.management",
          now,
          now,
          new Date(Date.now() + 60_000).toISOString(),
        );
    }
    const registrationBody = {
      contractVersion: "1.0",
      installationId,
      proposedWorkspaceName: "Test computer",
      hostname: "test-computer",
      platform: "macos",
      architecture: "arm64",
      appVersion: "1.0.0",
      runtimeCapabilities: {
        os: "macos",
        arch: "arm64",
        appVersion: "1.0.0",
        supportedRuntimes: ["dart"],
        maxConcurrentWorkers: 2,
      },
    };
    const register = (userId: string, extra: Record<string, unknown> = {}) =>
      handleRegisterWorkspaceFromDesktop(
        new Request(
          "https://app.conclave.test/api/workspace-runtime/register",
          {
            method: "POST",
            headers: {
              authorization: `Bearer ${userId}-secret`,
              "content-type": "application/json",
            },
            body: JSON.stringify({ ...registrationBody, ...extra }),
          },
        ),
        env,
      );

    const connected = await register("human-a");
    expect(connected.status).toBe(201);
    const firstRuntime = (await connected.json()) as {
      workspaceId: string;
      workspaceRuntimeId: string;
    };
    const recovered = await register("human-a", {
      existingWorkspaceId: firstRuntime.workspaceId,
      existingRuntimeId: firstRuntime.workspaceRuntimeId,
    });
    expect(recovered.status).toBe(201);
    const recoveredRuntime = (await recovered.json()) as {
      outcome: string;
      workspaceId: string;
      workspaceRuntimeId: string;
    };
    expect(recoveredRuntime).toMatchObject({
      outcome: "recovered",
      workspaceId: firstRuntime.workspaceId,
    });

    const accountSwitchDenied = await register("human-b");
    expect(accountSwitchDenied.status).toBe(409);
    expect(await accountSwitchDenied.json()).toMatchObject({
      code: "installation_already_owned",
    });

    const released = await handleReleaseDesktopWorkspace(
      new Request("https://app.conclave.test/api/workspace-runtime/release", {
        method: "POST",
        headers: {
          authorization: "Bearer human-a-secret",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          installationId,
          workspaceId: recoveredRuntime.workspaceId,
          runtimeId: recoveredRuntime.workspaceRuntimeId,
        }),
      }),
      env,
    );
    expect(released.status).toBe(200);
    const transferred = await register("human-b");
    expect(transferred.status).toBe(201);
    expect(await transferred.json()).toMatchObject({
      outcome: "created",
      ownerUserId: "human-b",
    });
  });

  it("rejects an incorrect comparison code and cannot approve the intent", async () => {
    const { env } = await setup();
    const create = await handleCreateDesktopAuthIntent(
      new Request("https://app.conclave.test/api/desktop-auth/intents", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          clientName: "Conclave Workspace",
          contractVersion: "1.0",
        }),
      }),
      env,
    );
    const intent = (await create.json()) as {
      intentId: string;
      userCode: string;
    };
    const wrongCode = intent.userCode === "00000000" ? "00000001" : "00000000";
    await expect(
      handleApproveDesktopAuthIntent(
        new Request("https://app.conclave.test/api/desktop-auth/approve", {
          method: "POST",
          headers: {
            cookie: "better-auth-session=opaque",
            "content-type": "application/json",
          },
          body: JSON.stringify({ userCode: wrongCode }),
        }),
        env,
        intent.intentId,
      ),
    ).rejects.toThrow(/code does not match/);
  });

  it("hashes the short-lived poll token and comparison code at rest", async () => {
    const { env, sqlite } = await setup();
    const response = await handleCreateDesktopAuthIntent(
      new Request("https://app.conclave.test/api/desktop-auth/intents", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          clientName: "Conclave Workspace",
          contractVersion: "1.0",
        }),
      }),
      env,
    );
    const intent = (await response.json()) as {
      intentId: string;
      userCode: string;
      pollToken: string;
    };
    const stored = sqlite
      .prepare(
        "SELECT user_code_hash, poll_token_hash FROM desktop_auth_intents WHERE id = ?",
      )
      .get(intent.intentId) as {
      user_code_hash: string;
      poll_token_hash: string;
    };
    expect(stored.user_code_hash).toBe(await hashToken(intent.userCode));
    expect(stored.poll_token_hash).toBe(await hashToken(intent.pollToken));
    expect(stored.poll_token_hash).not.toBe(intent.pollToken);
  });

  it("does not let another signed-in User claim an owned installation", async () => {
    const { env, sqlite } = await setup();
    const humanCredential = "conclave_dhs_user-b";
    const runtimeCredential = "conclave_workspace_tok_user-a";
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    const now = new Date().toISOString();
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-a", "a@example.test", "A", now, now);
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-b", "b@example.test", "B", now, now);
    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'offline', ?, ?)",
      )
      .run("workspace-a", "human-a", "A's Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_key_ref, credential_token_hash, installation_id, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      )
      .run(
        "runtime-a",
        "workspace-a",
        "runtime-a-key",
        await hashToken(runtimeCredential),
        installationId,
        now,
      );
    sqlite
      .prepare(
        "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        "session-b",
        "human-b",
        await hashToken(humanCredential),
        "conclave.desktop.management",
        now,
        now,
        new Date(Date.now() + 60_000).toISOString(),
      );

    const response = await handleRegisterWorkspaceFromDesktop(
      new Request("https://app.conclave.test/api/workspace-runtime/register", {
        method: "POST",
        headers: {
          authorization: `Bearer ${humanCredential}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId,
          proposedWorkspaceName: "B's computer",
          hostname: "b-computer",
          platform: "linux",
          architecture: "x64",
          appVersion: "1.0.0",
          runtimeCapabilities: {
            os: "linux",
            arch: "x64",
            appVersion: "1.0.0",
            supportedRuntimes: ["dart"],
            maxConcurrentWorkers: 2,
          },
        }),
      }),
      env,
    );
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({
      code: "installation_already_owned",
    });
    expect(
      sqlite
        .prepare(
          "SELECT COUNT(*) AS count FROM workspace_runtime_identities WHERE installation_id = ?",
        )
        .get(installationId),
    ).toMatchObject({ count: 1 });
  });

  it("blocks a different owner and safely migrates a legacy unbound runtime", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    const testUsers: Array<[string, string]> = [
      ["human-a", "a@example.test"],
      ["human-b", "b@example.test"],
    ];
    for (const [id, email] of testUsers) {
      sqlite
        .prepare(
          "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        )
        .run(id, email, id, now, now);
    }
    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'offline', ?, ?)",
      )
      .run("legacy-workspace", "human-a", "Legacy Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_key_ref, credential_token_hash, installation_id, created_at) VALUES (?, ?, ?, ?, NULL, ?)",
      )
      .run(
        "legacy-runtime",
        "legacy-workspace",
        "legacy-key",
        await hashToken("runtime-secret"),
        now,
      );
    const addSession = async (
      id: string,
      userId: string,
      credential: string,
    ) => {
      sqlite
        .prepare(
          "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .run(
          id,
          userId,
          await hashToken(credential),
          "conclave.desktop.management",
          now,
          now,
          new Date(Date.now() + 60_000).toISOString(),
        );
    };
    await addSession("session-b", "human-b", "human-b-secret");
    await addSession("session-a", "human-a", "human-a-secret");
    const request = (credential: string) =>
      new Request("https://app.conclave.test/api/workspace-runtime/ownership", {
        method: "POST",
        headers: {
          authorization: `Bearer ${credential}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId,
          workspaceId: "legacy-workspace",
          runtimeId: "legacy-runtime",
        }),
      });

    const denied = await handleCheckWorkspaceOwnership(
      request("human-b-secret"),
      env,
    );
    expect(denied.status).toBe(409);
    expect(await denied.json()).toMatchObject({
      code: "installation_already_owned",
    });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("legacy-runtime"),
    ).toMatchObject({ installation_id: null });

    const connectDenied = await handleRegisterWorkspaceFromDesktop(
      new Request("https://app.conclave.test/api/workspace-runtime/register", {
        method: "POST",
        headers: {
          authorization: "Bearer human-b-secret",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId,
          existingWorkspaceId: "legacy-workspace",
          existingRuntimeId: "legacy-runtime",
          proposedWorkspaceName: "B's computer",
          hostname: "b-computer",
          platform: "linux",
          architecture: "x64",
          appVersion: "1.0.0",
          runtimeCapabilities: {
            os: "linux",
            arch: "x64",
            appVersion: "1.0.0",
            supportedRuntimes: ["dart"],
            maxConcurrentWorkers: 2,
          },
        }),
      }),
      env,
    );
    expect(connectDenied.status).toBe(409);
    expect(await connectDenied.json()).toMatchObject({
      code: "installation_already_owned",
    });
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS count FROM workspace_runtime_identities")
        .get(),
    ).toMatchObject({ count: 1 });
    expect(
      sqlite
        .prepare(
          "SELECT credential_token_hash AS tokenHash FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("legacy-runtime"),
    ).toMatchObject({ tokenHash: await hashToken("runtime-secret") });

    const verified = await handleCheckWorkspaceOwnership(
      request("human-a-secret"),
      env,
    );
    expect(verified.status).toBe(200);
    expect(await verified.json()).toMatchObject({
      registered: true,
      ownerUserId: "human-a",
    });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("legacy-runtime"),
    ).toMatchObject({ installation_id: installationId });

    const mismatchedInstallation = await handleCheckWorkspaceOwnership(
      new Request("https://app.conclave.test/api/workspace-runtime/ownership", {
        method: "POST",
        headers: {
          authorization: "Bearer human-a-secret",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId: "install_abcdefab-cdef-4abc-8def-abcdefabcdef",
          workspaceId: "legacy-workspace",
          runtimeId: "legacy-runtime",
        }),
      }),
      env,
    );
    expect(mismatchedInstallation.status).toBe(409);
    expect(await mismatchedInstallation.json()).toMatchObject({
      code: "installation_already_owned",
    });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("legacy-runtime"),
    ).toMatchObject({ installation_id: installationId });

    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'offline', ?, ?)",
      )
      .run("workspace-other", "human-a", "Other Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_key_ref, credential_token_hash, installation_id, created_at) VALUES (?, ?, ?, ?, NULL, ?)",
      )
      .run(
        "runtime-other",
        "workspace-other",
        "other-key",
        await hashToken("other-runtime-secret"),
        now,
      );
    const mismatchedWorkspace = await handleCheckWorkspaceOwnership(
      new Request("https://app.conclave.test/api/workspace-runtime/ownership", {
        method: "POST",
        headers: {
          authorization: "Bearer human-a-secret",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId,
          workspaceId: "workspace-other",
          runtimeId: "runtime-other",
        }),
      }),
      env,
    );
    expect(mismatchedWorkspace.status).toBe(409);
    expect(await mismatchedWorkspace.json()).toMatchObject({
      code: "installation_already_owned",
    });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-other"),
    ).toMatchObject({ installation_id: null });
  });

  it("allows only a fresh Workspace owner session to release the installation binding", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-a", "a@example.test", "A", now, now);
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-b", "b@example.test", "B", now, now);
    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'offline', ?, ?)",
      )
      .run("workspace-a", "human-a", "A's Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_key_ref, credential_token_hash, installation_id, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      )
      .run(
        "runtime-a",
        "workspace-a",
        "runtime-key",
        await hashToken("runtime-secret"),
        installationId,
        now,
      );
    const addSession = async (
      id: string,
      userId: string,
      credential: string,
    ) => {
      sqlite
        .prepare(
          "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .run(
          id,
          userId,
          await hashToken(credential),
          "conclave.desktop.management",
          now,
          now,
          new Date(Date.now() + 60_000).toISOString(),
        );
    };
    await addSession("session-a", "human-a", "human-a-secret");
    await addSession("session-b", "human-b", "human-b-secret");
    const request = (credential: string) =>
      new Request("https://app.conclave.test/api/workspace-runtime/release", {
        method: "POST",
        headers: {
          authorization: `Bearer ${credential}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          installationId,
          workspaceId: "workspace-a",
          runtimeId: "runtime-a",
        }),
      });

    const denied = await handleReleaseDesktopWorkspace(
      request("human-b-secret"),
      env,
    );
    expect(denied.status).toBe(409);
    expect(await denied.json()).toMatchObject({
      code: "installation_already_owned",
    });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id, revoked_at FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-a"),
    ).toMatchObject({ installation_id: installationId, revoked_at: null });

    sqlite.exec("PRAGMA foreign_keys = OFF");
    sqlite
      .prepare(
        "INSERT INTO worker_assignments (id, project_id, execution_workspace_id, runtime_identity_id, worker_type_id, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 'running', ?, ?)",
      )
      .run(
        "assignment-active",
        "project-x",
        "workspace-a",
        "runtime-a",
        "worker-x",
        now,
        now,
      );
    const activeWorkDenied = await handleReleaseDesktopWorkspace(
      request("human-a-secret"),
      env,
    );
    expect(activeWorkDenied.status).toBe(409);
    expect(await activeWorkDenied.json()).toMatchObject({
      code: "active_work",
    });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id, revoked_at FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-a"),
    ).toMatchObject({ installation_id: installationId, revoked_at: null });
    expect(
      sqlite
        .prepare("SELECT status FROM execution_workspaces WHERE id = ?")
        .get("workspace-a"),
    ).toMatchObject({ status: "offline" });
    sqlite
      .prepare("DELETE FROM worker_assignments WHERE id = ?")
      .run("assignment-active");

    sqlite
      .prepare("UPDATE execution_workspaces SET status = 'online' WHERE id = ?")
      .run("workspace-a");
    const connectedReleaseDenied = await handleReleaseDesktopWorkspace(
      request("human-a-secret"),
      env,
    );
    expect(connectedReleaseDenied.status).toBe(409);
    expect(await connectedReleaseDenied.json()).toMatchObject({
      code: "runtime_connected",
    });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-a"),
    ).toMatchObject({ installation_id: installationId });
    sqlite
      .prepare(
        "UPDATE execution_workspaces SET status = 'offline' WHERE id = ?",
      )
      .run("workspace-a");

    const released = await handleReleaseDesktopWorkspace(
      request("human-a-secret"),
      env,
    );
    expect(released.status).toBe(200);
    expect(await released.json()).toMatchObject({
      released: true,
      installationId,
    });
    expect(
      sqlite
        .prepare(
          "SELECT installation_id, revoked_at FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-a"),
    ).toMatchObject({ installation_id: null });
    expect(
      sqlite
        .prepare("SELECT status FROM execution_workspaces WHERE id = ?")
        .get("workspace-a"),
    ).toMatchObject({ status: "revoked" });
  });

  it("disconnects through the owner human session and retains installation ownership", async () => {
    const { env, sqlite } = await setup();
    const now = new Date().toISOString();
    const installationId = "install_12345678-1234-4234-8234-123456789abc";
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-a", "a@example.test", "A", now, now);
    sqlite
      .prepare(
        "INSERT INTO execution_workspaces (id, owner_user_id, name, status, created_at, updated_at) VALUES (?, ?, ?, 'online', ?, ?)",
      )
      .run("workspace-a", "human-a", "A's Workspace", now, now);
    sqlite
      .prepare(
        "INSERT INTO workspace_runtime_identities (id, workspace_id, credential_key_ref, credential_token_hash, installation_id, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      )
      .run(
        "runtime-a",
        "workspace-a",
        "runtime-key",
        await hashToken("runtime-secret"),
        installationId,
        now,
      );
    sqlite
      .prepare(
        "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        "session-a",
        "human-a",
        await hashToken("human-a-secret"),
        "conclave.desktop.management",
        now,
        now,
        new Date(Date.now() + 60_000).toISOString(),
      );
    const gatewayFetch = vi.fn(async (request: RequestInfo | URL) => {
      const requestUrl =
        request instanceof Request ? request.url : String(request);
      expect(new URL(requestUrl).pathname).toBe("/disconnect-runtime");
      return Response.json({ disconnected: true });
    });
    (
      env as unknown as { CONCLAVE_WORKSPACE_GATEWAY: unknown }
    ).CONCLAVE_WORKSPACE_GATEWAY = {
      getByName: () => ({ fetch: gatewayFetch }),
    };
    const response = await handleDisconnectDesktopWorkspace(
      new Request(
        "https://app.conclave.test/api/workspace-runtime/disconnect",
        {
          method: "POST",
          headers: {
            authorization: "Bearer human-a-secret",
            "content-type": "application/json",
          },
          body: JSON.stringify({
            installationId,
            workspaceId: "workspace-a",
            runtimeId: "runtime-a",
          }),
        },
      ),
      env,
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      disconnected: true,
      gatewayDisconnected: true,
    });
    expect(gatewayFetch).toHaveBeenCalledOnce();
    expect(
      sqlite
        .prepare(
          "SELECT installation_id, revoked_at FROM workspace_runtime_identities WHERE id = ?",
        )
        .get("runtime-a"),
    ).toMatchObject({
      installation_id: installationId,
      revoked_at: expect.any(String),
    });
    expect(
      sqlite
        .prepare("SELECT status FROM execution_workspaces WHERE id = ?")
        .get("workspace-a"),
    ).toMatchObject({ status: "offline" });
    expect(
      sqlite
        .prepare(
          "SELECT action FROM workspace_audit_log WHERE workspace_id = ?",
        )
        .get("workspace-a"),
    ).toMatchObject({ action: "workspace.disconnected" });
  });

  it("rotates a valid desktop session without changing its owner or session ID", async () => {
    const { env, sqlite } = await setup();
    const oldCredential = "conclave_dhs_before_rotation";
    const now = new Date().toISOString();
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-a", "a@example.test", "A", now, now);
    sqlite
      .prepare(
        "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        "session-a",
        "human-a",
        await hashToken(oldCredential),
        "conclave.desktop.management",
        now,
        now,
        new Date(Date.now() + 60_000).toISOString(),
      );

    const response = await handleRotateDesktopHumanSession(
      new Request(
        "https://app.conclave.test/api/desktop-auth/sessions/session-a/rotate",
        {
          method: "POST",
          headers: { authorization: `Bearer ${oldCredential}` },
        },
      ),
      env,
      "session-a",
    );
    expect(response.status).toBe(200);
    const rotated = (await response.json()) as {
      credential: string;
      sessionId: string;
      audience: string;
      user: { userId: string };
      expiresAt: string;
    };
    expect(rotated.credential).not.toBe(oldCredential);
    expect(rotated.sessionId).toBe("session-a");
    expect(rotated.audience).toBe("conclave.desktop.management");
    expect(rotated.user.userId).toBe("human-a");
    expect(Date.parse(rotated.expiresAt)).toBeGreaterThan(Date.now());
    expect(
      sqlite
        .prepare("SELECT token_hash FROM desktop_human_sessions WHERE id = ?")
        .get("session-a"),
    ).toMatchObject({ token_hash: await hashToken(rotated.credential) });
    await expect(
      handleGetDesktopHumanSession(
        new Request("https://app.conclave.test/api/desktop-auth/session", {
          headers: { authorization: `Bearer ${oldCredential}` },
        }),
        env,
      ),
    ).rejects.toThrow(/invalid, expired, or revoked/);
  });

  it("returns the authenticated owner with a new Workspace registration", async () => {
    const { env, sqlite } = await setup();
    const humanCredential = "conclave_dhs_user-a";
    const now = new Date().toISOString();
    sqlite
      .prepare(
        "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      )
      .run("human-a", "a@example.test", "A", now, now);
    sqlite
      .prepare(
        "INSERT INTO desktop_human_sessions (id, user_id, token_hash, audience, created_at, last_used_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        "session-a",
        "human-a",
        await hashToken(humanCredential),
        "conclave.desktop.management",
        now,
        now,
        new Date(Date.now() + 60_000).toISOString(),
      );

    const response = await handleRegisterWorkspaceFromDesktop(
      new Request("https://app.conclave.test/api/workspace-runtime/register", {
        method: "POST",
        headers: {
          authorization: `Bearer ${humanCredential}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId: "install_12345678-1234-4234-8234-123456789abc",
          proposedWorkspaceName: "A's computer",
          hostname: "a-computer",
          platform: "macos",
          architecture: "arm64",
          appVersion: "1.0.0",
          runtimeCapabilities: {
            os: "macos",
            arch: "arm64",
            appVersion: "1.0.0",
            supportedRuntimes: ["dart"],
            maxConcurrentWorkers: 2,
          },
        }),
      }),
      env,
    );

    expect(response.status).toBe(201);
    expect(await response.json()).toMatchObject({
      outcome: "created",
      ownerUserId: "human-a",
      workspaceName: "A's computer",
    });

    const updateResponse = await handleRegisterWorkspaceFromDesktop(
      new Request("https://app.conclave.test/api/workspace-runtime/register", {
        method: "POST",
        headers: {
          authorization: `Bearer ${humanCredential}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          contractVersion: "1.0",
          installationId: "install_12345678-1234-4234-8234-123456789abc",
          proposedWorkspaceName: "Updated Workspace Name",
          hostname: "a-computer",
          platform: "macos",
          architecture: "arm64",
          appVersion: "1.0.0",
          runtimeCapabilities: {
            os: "macos",
            arch: "arm64",
            appVersion: "1.0.0",
            supportedRuntimes: ["dart"],
            maxConcurrentWorkers: 2,
          },
        }),
      }),
      env,
    );

    expect(updateResponse.status).toBe(201);
    expect(await updateResponse.json()).toMatchObject({
      outcome: "recovered",
      ownerUserId: "human-a",
      workspaceName: "Updated Workspace Name",
    });

    const workspaceRecord = sqlite
      .prepare("SELECT name FROM execution_workspaces LIMIT 1")
      .get() as { name: string };
    expect(workspaceRecord.name).toBe("Updated Workspace Name");
  });
});
