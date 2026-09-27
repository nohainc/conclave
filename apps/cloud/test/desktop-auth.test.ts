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
  handleGetDesktopHumanSession,
  handleRegisterWorkspaceFromDesktop,
  handleRevokeDesktopHumanSession,
} from "../src/routes/handlers.js";

const migrationsDirectory = fileURLToPath(
  new URL("../migrations-v6/", import.meta.url),
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
    const env = { CONCLAVE_DB: db } as never;
    vi.spyOn(identityService, "resolve").mockResolvedValue({
      userId: "human-1",
      email: "person@example.test",
      name: "Person",
      sessionId: "browser-session-1",
    });
    return { db, env, sqlite };
  }

  it("exchanges an approved browser intent once for an independently revocable desktop session", async () => {
    const { env, sqlite } = await setup();
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
    expect(create.status).toBe(201);
    const intent = (await create.json()) as {
      intentId: string;
      userCode: string;
      pollToken: string;
      verificationUrl: string;
    };
    expect(new URL(intent.verificationUrl).pathname).toBe(
      "/desktop-auth/approve",
    );

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
        body: JSON.stringify({ userCode: intent.userCode }),
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
});
