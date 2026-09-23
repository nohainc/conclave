import { describe, expect, it } from "vitest";
import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import worker from "../src/index.js";
import { createEventPublisher } from "../src/event-publisher.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const schemaPath = path.resolve(here, "../migrations-v4/0001_conclave_v4.sql");
const migrationPaths = [
  schemaPath,
  ...[2, 3, 4, 5, 6].map((number) =>
    path.resolve(
      here,
      "../migrations-v4",
      fs
        .readdirSync(path.resolve(here, "../migrations-v4"))
        .find((file) => file.startsWith(`000${number}_`))!,
    ),
  ),
];

type SqliteStatement = {
  sql: string;
  values: unknown[];
};

/** Small D1 adapter backed by the same SQLite engine used by the schema tests. */
class LocalD1Statement {
  readonly statement: SqliteStatement;

  get sql(): string {
    return this.statement.sql;
  }

  constructor(
    private readonly db: DatabaseSync,
    sql: string,
    values: unknown[] = [],
  ) {
    this.statement = { sql, values };
  }

  bind(...values: unknown[]): LocalD1Statement {
    return new LocalD1Statement(this.db, this.statement.sql, values);
  }

  async first<T = Record<string, unknown>>(): Promise<T | null> {
    const row = this.db
      .prepare(this.statement.sql)
      .get(...(this.statement.values as SQLInputValue[])) as T | undefined;
    return row ?? null;
  }

  async all<T = Record<string, unknown>>(): Promise<{
    results: T[];
    meta: { changes: number; last_row_id: number };
  }> {
    if (this.statement.sql.includes("pragma_table_info")) {
      const table = String(this.statement.values[0] ?? "").replaceAll(
        "'",
        "''",
      );
      return {
        results: this.db.prepare(`PRAGMA table_info('${table}')`).all() as T[],
        meta: { changes: 0, last_row_id: 0 },
      };
    }
    return {
      results: this.db
        .prepare(this.statement.sql)
        .all(...(this.statement.values as SQLInputValue[])) as T[],
      meta: { changes: 0, last_row_id: 0 },
    };
  }

  async run(): Promise<{
    success: true;
    meta: { changes: number; last_row_id: number };
  }> {
    const result = this.db
      .prepare(this.statement.sql)
      .run(...(this.statement.values as SQLInputValue[]));
    return {
      success: true,
      meta: {
        changes: Number(result.changes),
        last_row_id: Number(result.lastInsertRowid),
      },
    };
  }

  async raw<T = unknown[]>(): Promise<T[]> {
    return this.db
      .prepare(this.statement.sql)
      .all(...(this.statement.values as SQLInputValue[]))
      .map((row) => Object.values(row)) as T[];
  }
}

class LocalD1 {
  constructor(readonly sqlite: DatabaseSync) {}

  exec(sql: string): void {
    this.sqlite.exec(sql);
  }

  prepare(sql: string): LocalD1Statement {
    return new LocalD1Statement(this.sqlite, sql);
  }

  async batch(statements: readonly LocalD1Statement[]): Promise<unknown[]> {
    this.sqlite.exec("BEGIN");
    try {
      const results: unknown[] = [];
      for (const statement of statements) {
        results.push(
          /^\s*(select|pragma)/i.test(statement.sql)
            ? await statement.all()
            : await statement.run(),
        );
      }
      this.sqlite.exec("COMMIT");
      return results;
    } catch (error) {
      this.sqlite.exec("ROLLBACK");
      throw error;
    }
  }
}

type WorkflowParams = { runId: string };

function createTestEnvironment() {
  const sqlite = new DatabaseSync(":memory:");
  sqlite.exec("PRAGMA foreign_keys = ON;");
  for (const migrationPath of migrationPaths) {
    sqlite.exec(fs.readFileSync(migrationPath, "utf8"));
  }
  const db = new LocalD1(sqlite);

  sqlite
    .prepare(
      `INSERT INTO workers
       (id, display_name, description, publisher, status, created_at, updated_at)
       VALUES ('codex', 'Codex Worker', 'Deterministic Codex acceptance Worker.', 'Conclave', 'active', 'now', 'now')`,
    )
    .run();
  sqlite
    .prepare(
      `INSERT INTO worker_versions
       (id, worker_id, version, protocol_version, min_host_version,
        supported_os_json, supported_arch_json, entrypoint, package_digest,
        package_r2_key, signature, created_at)
       VALUES ('codex-v1', 'codex', '1.0.0', '4.0', '4.0.0',
        '["macos","linux","windows"]', '["arm64","x64"]',
        'codex_worker', 'sha256:test', 'workers/codex/1.0.0',
        'test-signature', 'now')`,
    )
    .run();

  const workflowInstances = new Map<string, { status: string }>();
  const realtimeTrace: string[] = [];
  const eventPublisher = createEventPublisher({
    CONCLAVE_DB: db as unknown as D1Database,
  });
  const workflow = {
    create: async ({ params }: { params: WorkflowParams }) => {
      const run = sqlite
        .prepare(
          `SELECT workspace_id AS workspaceId, project_id AS projectId
           FROM runs WHERE id = ?`,
        )
        .get(params.runId) as
        { workspaceId: string; projectId: string } | undefined;
      if (!run) throw new Error(`Run ${params.runId} was not created`);

      // The acceptance harness uses a deterministic Worker execution adapter.
      // It goes through the same event publisher as a real Host, so the test
      // verifies the durable/realtime contract without calling an external AI.
      const publish = async (
        type: string,
        durable: boolean,
        payload: Record<string, unknown>,
      ) => {
        realtimeTrace.push(type);
        await eventPublisher.publish({
          type,
          durable,
          workspaceId: run.workspaceId,
          projectId: run.projectId,
          runId: params.runId,
          idempotencyKey: `e2e:${params.runId}:${type}`,
          payload,
        });
      };

      workflowInstances.set(params.runId, { status: "completed" });
      await publish("run.started", true, {
        entityId: params.runId,
        status: "running",
      });
      await publish("assignment.progress", false, {
        entityId: params.runId,
        status: "research",
        percentage: 25,
      });
      await publish("task.started", true, {
        entityId: params.runId,
        status: "implementation",
      });
      await publish("task.completed", true, {
        entityId: params.runId,
        status: "review",
      });
      await publish("verification.completed", true, {
        entityId: params.runId,
        status: "verified",
        summary: "Deterministic acceptance verification completed",
      });
      sqlite
        .prepare(
          "UPDATE runs SET status = 'completed', finished_at = 'now', updated_at = 'now' WHERE id = ?",
        )
        .run(params.runId);
      await publish("run.completed", true, {
        entityId: params.runId,
        status: "completed",
        summary: "Verified result produced by Codex Worker",
      });
      return {
        status: async () => ({ status: "completed" }),
      };
    },
    get: async (id: string) => ({
      status: async () => ({
        status: workflowInstances.get(id)?.status ?? "completed",
      }),
    }),
  };

  const env = {
    CONCLAVE_ENVIRONMENT: "development",
    CONCLAVE_E2E: "true",
    BETTER_AUTH_SECRET:
      "a-local-e2e-secret-that-is-long-enough-for-better-auth",
    BETTER_AUTH_URL: "https://conclave.e2e.test",
    BETTER_AUTH_TRUSTED_ORIGINS: "https://conclave.e2e.test",
    CONCLAVE_DB: db,
    CONCLAVE_RUN_WORKFLOW: workflow,
  } as never;

  return { db, env, sqlite, realtimeTrace };
}

class BrowserSession {
  private readonly cookies = new Map<string, string>();
  private activeWorkspaceId: string | undefined;

  constructor(
    private readonly env: never,
    private readonly origin = "https://conclave.e2e.test",
  ) {}

  setActiveWorkspace(workspaceId: string): void {
    this.activeWorkspaceId = workspaceId;
  }

  async request(
    pathname: string,
    init: RequestInit = {},
  ): Promise<{ response: Response; body: Record<string, unknown> }> {
    const headers = new Headers(init.headers);
    headers.set("origin", this.origin);
    headers.set("accept", "application/json");
    if (this.activeWorkspaceId) {
      headers.set("x-conclave-workspace-id", this.activeWorkspaceId);
    }
    if (init.body && !headers.has("content-type")) {
      headers.set("content-type", "application/json");
    }
    if (this.cookies.size > 0) {
      headers.set(
        "cookie",
        [...this.cookies].map(([name, value]) => `${name}=${value}`).join("; "),
      );
    }

    const response = await worker.fetch(
      new Request(`${this.origin}${pathname}`, { ...init, headers }),
      this.env,
    );
    const setCookies = response.headers.getSetCookie?.() ?? [];
    for (const setCookie of setCookies) {
      const match = setCookie.match(/^([^=]+)=([^;]*)/);
      if (match?.[1] && match[2] !== undefined) {
        this.cookies.set(match[1], match[2]);
      }
    }
    const body = (await response.json().catch(() => ({}))) as Record<
      string,
      unknown
    >;
    return { response, body };
  }

  async post(pathname: string, body: Record<string, unknown>) {
    return this.request(pathname, {
      method: "POST",
      body: JSON.stringify(body),
    });
  }

  async get(pathname: string) {
    return this.request(pathname);
  }

  async put(pathname: string, body: Record<string, unknown>) {
    return this.request(pathname, {
      method: "PUT",
      body: JSON.stringify(body),
    });
  }
}

async function expectOk(
  operation: Promise<{
    response: Response;
    body: Record<string, unknown>;
  }>,
  status: number | number[] = 200,
) {
  const result = await operation;
  const expected = Array.isArray(status) ? status : [status];
  expect(expected).toContain(result.response.status);
  return result.body;
}

describe("clean-room first-user acceptance", () => {
  it("takes a new user from sign-in to a verified Codex result", async () => {
    const { env, sqlite, realtimeTrace } = createTestEnvironment();
    for (const table of [
      "users",
      "workspaces",
      "projects",
      "hosts",
      "credential_profiles",
      "host_worker_installations",
      "worker_assignments",
    ]) {
      expect(
        sqlite.prepare(`SELECT COUNT(*) AS count FROM ${table}`).get(),
      ).toEqual({ count: 0 });
    }
    const alice = new BrowserSession(env);

    await expectOk(
      alice.post("/api/auth/sign-up/email", {
        name: "Alice",
        email: "alice@example.test",
        password: "correct horse battery staple",
      }),
      200,
    );
    const session = await expectOk(alice.get("/api/session"));
    expect(session.authenticated).toBe(true);

    const workspaces = await expectOk(alice.get("/api/workspaces"));
    const workspace = (
      workspaces.workspaces as Array<Record<string, unknown>>
    )[0];
    expect(workspace).toBeTruthy();
    if (!workspace) throw new Error("Personal Workspace was not provisioned");
    expect(workspace.name).toContain("Personal Workspace");
    const workspaceId = String(workspace.id);

    expect(
      sqlite.prepare("SELECT COUNT(*) AS count FROM projects").get(),
    ).toEqual({ count: 0 });
    expect(sqlite.prepare("SELECT COUNT(*) AS count FROM hosts").get()).toEqual(
      { count: 0 },
    );
    expect(
      sqlite.prepare("SELECT COUNT(*) AS count FROM credential_profiles").get(),
    ).toEqual({ count: 0 });

    const enrollment = await expectOk(
      alice.post(`/api/workspaces/${workspaceId}/host-enrollments`, {
        expiresHours: 1,
      }),
      201,
    );
    const host = await expectOk(
      alice.post("/api/hosts/enroll", {
        token: enrollment.token,
        hostId: "host-alice",
        name: "Alice MacBook",
        hostname: "alice-macbook",
      }),
      201,
    );
    expect(host.workspaceId).toBe(workspaceId);

    await expectOk(
      alice.put(`/api/workspaces/${workspaceId}/workers/codex`, {
        enabled: true,
        hostId: host.hostId,
        version: "1.0.0",
      }),
    );
    expect(
      sqlite
        .prepare(
          "SELECT required_version FROM host_desired_workers WHERE host_id = 'host-alice' AND worker_id = 'codex'",
        )
        .get(),
    ).toEqual({ required_version: "1.0.0" });

    const account = await expectOk(
      alice.post(`/api/workspaces/${workspaceId}/accounts`, {
        displayName: "Alice Codex",
        workerId: "codex",
        // Codex is represented by the deterministic no-auth Worker in this
        // clean-room test; raw provider credentials never enter D1.
        authType: "none",
        ownerType: "user",
        sharingPolicy: "private_only",
      }),
      201,
    );
    expect((account.account as Record<string, unknown>).status).toBe("ready");

    const project = await expectOk(
      alice.post("/api/projects", { name: "Authentication redesign" }),
      201,
    );
    const projectRecord = project.project as Record<string, unknown>;
    const projectId = String(projectRecord.id);
    expect(projectRecord.workspaceId).toBe(workspaceId);

    const chat = await expectOk(
      alice.post(`/api/projects/${projectId}/chats`, {
        title: "First execution",
      }),
      201,
    );
    const chatId = String((chat.chat as Record<string, unknown>).id);

    const messageResult = await alice.post(`/api/chats/${chatId}/messages`, {
      content: "Review this repository and improve authentication",
    });
    expect(
      messageResult.response.status,
      JSON.stringify(messageResult.body),
    ).toBe(201);
    const message = messageResult.body;
    expect(message.intent).toBeTruthy();
    expect(message.runId).toBeTruthy();
    const runId = String(message.runId);

    expect(realtimeTrace).toEqual([
      "run.started",
      "assignment.progress",
      "task.started",
      "task.completed",
      "verification.completed",
      "run.completed",
    ]);
    const durableEvents = sqlite
      .prepare(
        "SELECT event_type FROM realtime_events WHERE run_id = ? ORDER BY sequence",
      )
      .all(runId) as Array<{ event_type: string }>;
    expect(durableEvents.map((event) => event.event_type)).toEqual([
      "run.started",
      "task.started",
      "task.completed",
      "verification.completed",
      "run.completed",
    ]);

    const refreshedProjectResult = await alice.get(
      `/api/projects/${projectId}/read-model`,
    );
    expect(
      refreshedProjectResult.response.status,
      JSON.stringify(refreshedProjectResult.body),
    ).toBe(200);
    const refreshedProject = refreshedProjectResult.body;
    expect((refreshedProject.project as Record<string, unknown>).id).toBe(
      projectId,
    );
    const refreshedChat = await expectOk(
      alice.get(`/api/chats/${chatId}/messages`),
    );
    expect((refreshedChat.messages as unknown[]).length).toBeGreaterThan(0);
    const refreshedRun = await expectOk(alice.get(`/api/runs/${runId}`));
    expect(refreshedRun.status).toBe("completed");

    const invitation = await expectOk(
      alice.post(`/api/workspaces/${workspaceId}/invitations`, {
        email: "bob@example.test",
        role: "member",
      }),
      201,
    );
    const bob = new BrowserSession(env);
    await expectOk(
      bob.post("/api/auth/sign-up/email", {
        name: "Bob",
        email: "bob@example.test",
        password: "correct horse battery staple",
      }),
      200,
    );
    await expectOk(bob.post(`/api/invitations/${invitation.token}/accept`, {}));
    const bobWorkspaces = await expectOk(bob.get("/api/workspaces"));
    expect(
      (bobWorkspaces.workspaces as Array<Record<string, unknown>>).some(
        (item) => item.id === workspaceId,
      ),
    ).toBe(true);
    bob.setActiveWorkspace(workspaceId);

    const bobHosts = await expectOk(
      bob.get(`/api/workspaces/${workspaceId}/hosts`),
    );
    expect(
      (bobHosts.hosts as Array<Record<string, unknown>>).map((item) => item.id),
    ).toContain("host-alice");
    const bobAccounts = await expectOk(
      bob.get(`/api/workspaces/${workspaceId}/accounts`),
    );
    const visibleAccountIds = (
      bobAccounts.accounts as Array<Record<string, unknown>>
    ).map((item) => item.id);
    expect(visibleAccountIds).not.toContain(
      String((account.account as Record<string, unknown>).id),
    );
  });
});
