import { beforeEach, describe, expect, it } from "vitest";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import worker from "../src/index.js";
import { hashToken } from "../../../packages/security/src/index.js";

const here = path.dirname(fileURLToPath(import.meta.url));

function d1Mock(db: DatabaseSync) {
  return {
    prepare(query: string) {
      let params: Array<string | number | bigint | null | Uint8Array> = [];
      const statement = {
        bind(...values: unknown[]) {
          params = values as Array<
            string | number | bigint | null | Uint8Array
          >;
          return statement;
        },
        async first<T>() {
          return (db.prepare(query).get(...params) as T | undefined) ?? null;
        },
        async all<T>() {
          return { results: db.prepare(query).all(...params) as T[] };
        },
        async run() {
          const result = db.prepare(query).run(...params);
          return { success: true, meta: { changes: Number(result.changes) } };
        },
      };
      return statement;
    },
    async batch(statements: Array<{ run: () => Promise<unknown> }>) {
      for (const statement of statements) await statement.run();
    },
  };
}

describe("V2-21 workspace collaboration", () => {
  let db: DatabaseSync;
  let env: Env;

  beforeEach(() => {
    db = new DatabaseSync(":memory:");
    db.exec("PRAGMA foreign_keys = ON;");
    const migrations = path.resolve(here, "../migrations");
    for (const migration of fs
      .readdirSync(migrations)
      .filter((file) => file.endsWith(".sql"))
      .sort()) {
      db.exec(fs.readFileSync(path.join(migrations, migration), "utf8"));
    }
    env = {
      CONCLAVE_ENVIRONMENT: "production",
      CONCLAVE_DB: d1Mock(db),
      CONCLAVE_RUN_WORKFLOW: {
        create: async () => ({ status: async () => ({ status: "running" }) }),
        get: async () => ({
          pause: async () => undefined,
          status: async () => ({ status: "paused" }),
        }),
      },
    } as unknown as Env;
  });

  async function user(id: string, email: string) {
    const token = `session-${id}`;
    const now = new Date().toISOString();
    db.prepare(
      `INSERT INTO users (id, email, display_name, status, created_at, updated_at)
       VALUES (?, ?, ?, 'active', ?, ?)`,
    ).run(id, email, id, now, now);
    db.prepare(
      `INSERT INTO auth_sessions (id, user_id, token_hash, client_type, expires_at, created_at, updated_at)
       VALUES (?, ?, ?, 'desktop', ?, ?, ?)`,
    ).run(
      `session-row-${id}`,
      id,
      await hashToken(token),
      new Date(Date.now() + 86400000).toISOString(),
      now,
      now,
    );
    return token;
  }

  it("invites a second user into a project, preserves isolation, and attributes control", async () => {
    const alice = await user("alice", "alice@example.com");
    const bob = await user("bob", "bob@example.com");
    const headers = (token: string, workspaceId?: string) => ({
      authorization: `Bearer ${token}`,
      ...(workspaceId ? { "x-conclave-workspace-id": workspaceId } : {}),
    });

    const workspaceResponse = await worker.fetch(
      new Request("https://cloud/api/workspaces", {
        method: "POST",
        headers: { ...headers(alice), "content-type": "application/json" },
        body: JSON.stringify({ name: "Shared workspace" }),
      }),
      env,
    );
    const { workspace } = (await workspaceResponse.json()) as {
      workspace: { id: string };
    };
    const workspaceId = workspace.id;
    const storedBackups = new Map<string, string>();
    (
      env as unknown as { CONCLAVE_SECURITY_KEY: string }
    ).CONCLAVE_SECURITY_KEY = "test-backup-key";
    (env as unknown as { CONCLAVE_ARTIFACTS: R2Bucket }).CONCLAVE_ARTIFACTS = {
      async put(key: string, value: string) {
        storedBackups.set(key, value);
      },
      async get(key: string) {
        const value = storedBackups.get(key);
        return value == null ? null : { text: async () => value };
      },
    } as unknown as R2Bucket;

    const projectResponse = await worker.fetch(
      new Request("https://cloud/api/projects", {
        method: "POST",
        headers: {
          ...headers(alice, workspaceId),
          "content-type": "application/json",
        },
        body: JSON.stringify({ name: "Shared project" }),
      }),
      env,
    );
    const { project } = (await projectResponse.json()) as {
      project: { id: string };
    };
    const chatResponse = await worker.fetch(
      new Request(`https://cloud/api/projects/${project.id}/chats`, {
        method: "POST",
        headers: {
          ...headers(alice, workspaceId),
          "content-type": "application/json",
        },
        body: JSON.stringify({ title: "Shared chat" }),
      }),
      env,
    );
    const { chat } = (await chatResponse.json()) as { chat: { id: string } };

    const inviteResponse = await worker.fetch(
      new Request(`https://cloud/api/workspaces/${workspaceId}/invitations`, {
        method: "POST",
        headers: {
          ...headers(alice, workspaceId),
          "content-type": "application/json",
        },
        body: JSON.stringify({
          email: "bob@example.com",
          projectId: project.id,
          role: "member",
        }),
      }),
      env,
    );
    expect(inviteResponse.status).toBe(201);
    const invite = (await inviteResponse.json()) as { token: string };

    const acceptResponse = await worker.fetch(
      new Request(`https://cloud/api/invitations/${invite.token}/accept`, {
        method: "POST",
        headers: headers(bob),
      }),
      env,
    );
    expect(acceptResponse.status).toBe(200);

    const bobProjects = await worker.fetch(
      new Request("https://cloud/api/projects", {
        headers: headers(bob, workspaceId),
      }),
      env,
    );
    expect(
      (
        (await bobProjects.json()) as { projects: Array<{ id: string }> }
      ).projects.map((p) => p.id),
    ).toEqual([project.id]);

    const bobChats = await worker.fetch(
      new Request(`https://cloud/api/projects/${project.id}/chats`, {
        headers: headers(bob, workspaceId),
      }),
      env,
    );
    expect(
      ((await bobChats.json()) as { chats: Array<{ id: string }> }).chats.map(
        (c) => c.id,
      ),
    ).toEqual([chat.id]);

    const foreignProject = db.prepare(
      `INSERT INTO projects (id, workspace_id, name, settings_json, created_at, updated_at) VALUES (?, ?, ?, '{}', ?, ?)`,
    );
    const otherWorkspace = `ws-other-${crypto.randomUUID()}`;
    const now = new Date().toISOString();
    db.prepare(
      "INSERT INTO workspaces (id, name, slug, status, created_at, updated_at) VALUES (?, ?, ?, 'active', ?, ?)",
    ).run(otherWorkspace, "Other", `other-${Date.now()}`, now, now);
    foreignProject.run("project-foreign", otherWorkspace, "Foreign", now, now);
    const isolated = await worker.fetch(
      new Request("https://cloud/api/projects", {
        headers: headers(bob, otherWorkspace),
      }),
      env,
    );
    expect(isolated.status).toBe(403);

    const runId = "run-shared";
    const goalId = "goal-shared";
    db.prepare(
      `INSERT INTO goals (id, workspace_id, project_id, chat_id, original_message, objective, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, 'running', ?, ?)`,
    ).run(
      goalId,
      workspaceId,
      project.id,
      chat.id,
      "Shared run",
      "Shared run",
      now,
      now,
    );
    db.prepare(
      `INSERT INTO runs (id, workspace_id, project_id, goal_id, policy_snapshot_json, status, created_at, updated_at) VALUES (?, ?, ?, ?, '{}', 'running', ?, ?)`,
    ).run(runId, workspaceId, project.id, goalId, now, now);
    const pause = await worker.fetch(
      new Request(`https://cloud/api/runs/${runId}/pause`, {
        method: "POST",
        headers: headers(bob, workspaceId),
      }),
      env,
    );
    expect(pause.status).toBe(200);
    const audit = db
      .prepare(
        "SELECT actor_id, action, target_id FROM audit_log WHERE target_id = ? ORDER BY created_at DESC LIMIT 1",
      )
      .get(runId) as { actor_id: string; action: string; target_id: string };
    expect(audit).toEqual({
      actor_id: "bob",
      action: "run.pause",
      target_id: runId,
    });

    const auditExport = await worker.fetch(
      new Request(`https://cloud/api/workspaces/${workspaceId}/audit-export`, {
        headers: headers(alice, workspaceId),
      }),
      env,
    );
    expect(auditExport.status).toBe(200);
    const exportBody = (await auditExport.json()) as {
      format: string;
      workspaceId: string;
      entries: Array<{ workspaceId: string; actorId: string }>;
    };
    expect(exportBody.format).toBe("conclave-audit-log-v1");
    expect(exportBody.workspaceId).toBe(workspaceId);
    expect(exportBody.entries.length).toBeGreaterThan(0);
    expect(
      exportBody.entries.every((entry) => entry.workspaceId === workspaceId),
    ).toBe(true);

    const memberAuditExport = await worker.fetch(
      new Request(`https://cloud/api/workspaces/${workspaceId}/audit-export`, {
        headers: headers(bob, workspaceId),
      }),
      env,
    );
    expect(memberAuditExport.status).toBe(403);

    const backupResponse = await worker.fetch(
      new Request(`https://cloud/api/workspaces/${workspaceId}/backup`, {
        method: "POST",
        headers: headers(alice, workspaceId),
      }),
      env,
    );
    expect(backupResponse.status).toBe(201);
    const backupBody = (await backupResponse.json()) as {
      format: string;
      workspaceId: string;
      storageKey: string;
      digest: string;
    };
    expect(backupBody.format).toBe("conclave-encrypted-backup-v1");
    expect(backupBody.workspaceId).toBe(workspaceId);
    expect(backupBody.digest).toMatch(/^sha256:/);
    expect(storedBackups.has(backupBody.storageKey)).toBe(true);
    expect(storedBackups.get(backupBody.storageKey)).toContain(
      '"workspaceId":"' + workspaceId + '"',
    );

    const restoreDrill = await worker.fetch(
      new Request(
        `https://cloud/api/workspaces/${workspaceId}/backup/restore-drill`,
        {
          method: "POST",
          headers: {
            ...headers(alice, workspaceId),
            "content-type": "application/json",
          },
          body: JSON.stringify({ storageKey: backupBody.storageKey }),
        },
      ),
      env,
    );
    expect(restoreDrill.status).toBe(200);
    const restoreBody = (await restoreDrill.json()) as {
      format: string;
      digest: string;
      tableCounts: Record<string, number>;
    };
    expect(restoreBody.format).toBe("conclave-backup-restore-drill-v1");
    expect(restoreBody.digest).toBe(backupBody.digest);
    expect(restoreBody.tableCounts.workspaces).toBe(1);
    expect(restoreBody.tableCounts.projects).toBe(1);

    const memberBackup = await worker.fetch(
      new Request(`https://cloud/api/workspaces/${workspaceId}/backup`, {
        method: "POST",
        headers: headers(bob, workspaceId),
      }),
      env,
    );
    expect(memberBackup.status).toBe(403);
  });
});
