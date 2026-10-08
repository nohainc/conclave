import { DatabaseSync } from "node:sqlite";
import { expect, it, vi } from "vitest";

vi.mock("../src/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  securityContext: async () => ({
    userId: "user-123",
    user: {
      id: "user-123",
      email: "vitalii@nohainc.com",
      displayName: "Vitalii",
    },
  }),
}));

import { handleGetHomeReadModel } from "../src/routes/home.js";

it("projects authorized Home read model with attention, running, recentWork, productUpdates, and aiUpdates", async () => {
  const sqlite = new DatabaseSync(":memory:");
  try {
    sqlite.exec(`
      CREATE TABLE users (id TEXT, email TEXT, display_name TEXT, status TEXT);
      CREATE TABLE projects (id TEXT, name TEXT, description TEXT, settings_json TEXT, created_at TEXT, updated_at TEXT);
      CREATE TABLE project_memberships (id TEXT, project_id TEXT, user_id TEXT, role TEXT, created_at TEXT, updated_at TEXT);
      CREATE TABLE project_invitations (id TEXT, project_id TEXT, email TEXT, role TEXT, status TEXT, invited_by_user_id TEXT, expires_at TEXT, created_at TEXT, updated_at TEXT);
      CREATE TABLE workstreams (id TEXT, project_id TEXT, name TEXT, status TEXT, access_policy_json TEXT, lead_user_id TEXT, created_at TEXT, updated_at TEXT);
      CREATE TABLE work_requests (id TEXT, project_id TEXT, workstream_id TEXT, requested_by_user_id TEXT, workflow_id TEXT, workflow_version TEXT, workflow_snapshot_json TEXT, snapshot_json TEXT, input_json TEXT, status TEXT, created_at TEXT, updated_at TEXT);
      CREATE TABLE discussion_messages (id TEXT, workstream_id TEXT, user_id TEXT, content TEXT, created_at TEXT, updated_at TEXT);
      CREATE TABLE conversation_history_entries (id TEXT, work_request_id TEXT, conversation_id TEXT, kind TEXT, text TEXT, created_at TEXT);
      CREATE TABLE conversation_work_requests (work_request_id TEXT, conversation_id TEXT, workstream_id TEXT);

      -- Users
      INSERT INTO users VALUES ('user-123', 'vitalii@nohainc.com', 'Vitalii', 'active');
      INSERT INTO users VALUES ('user-inviter', 'julia@nohainc.com', 'Julia', 'active');

      -- Authorized Project
      INSERT INTO projects VALUES ('proj-auth', 'Authorized Project', 'Active project', '{"archived":false}', '2026-10-01T00:00:00Z', '2026-10-08T00:00:00Z');
      INSERT INTO project_memberships VALUES ('pm-1', 'proj-auth', 'user-123', 'owner', '2026-10-01T00:00:00Z', '2026-10-08T00:00:00Z');

      -- Revoked / Unauthorized Project (user is not a member)
      INSERT INTO projects VALUES ('proj-revoked', 'Revoked Project', 'Revoked', '{"archived":false}', '2026-10-01T00:00:00Z', '2026-10-08T00:00:00Z');

      -- Pending Invitation for user
      INSERT INTO project_invitations VALUES ('inv-1', 'proj-auth', 'vitalii@nohainc.com', 'editor', 'pending', 'user-inviter', '2026-11-01T00:00:00Z', '2026-10-08T00:00:00Z', '2026-10-08T00:00:00Z');

      -- Workstream in authorized project
      INSERT INTO workstreams VALUES ('ws-auth', 'proj-auth', 'Core Architecture', 'active', '{}', 'user-123', '2026-10-02T00:00:00Z', '2026-10-08T05:00:00Z');
      INSERT INTO discussion_messages VALUES ('msg-1', 'ws-auth', 'user-123', 'Home read model projection complete.', '2026-10-08T05:00:00Z', '2026-10-08T05:00:00Z');

      -- Workstream in revoked project (must NOT appear)
      INSERT INTO workstreams VALUES ('ws-revoked', 'proj-revoked', 'Secret Workstream', 'active', '{}', 'other', '2026-10-02T00:00:00Z', '2026-10-08T05:00:00Z');

      -- Active Run in authorized project
      INSERT INTO work_requests VALUES ('run-active', 'proj-auth', 'ws-auth', 'user-123', 'full_cycle', '1.0.0', '{}', '{}', '{"objective":"Building Home API projection"}', 'running', '2026-10-08T05:10:00Z', '2026-10-08T05:10:00Z');

      -- Active Run in revoked project (must NOT appear)
      INSERT INTO work_requests VALUES ('run-secret', 'proj-revoked', 'ws-revoked', 'other', 'full_cycle', '1.0.0', '{}', '{}', '{"objective":"Secret Execution"}', 'running', '2026-10-08T05:10:00Z', '2026-10-08T05:10:00Z');

      -- Failed execution in authorized project (attention item)
      INSERT INTO work_requests VALUES ('run-failed', 'proj-auth', 'ws-auth', 'user-123', 'full_cycle', '1.0.0', '{}', '{}', '{"objective":"Flaky task"}', 'failed', '2026-10-08T04:00:00Z', '2026-10-08T04:30:00Z');
    `);

    const db = {
      prepare(sql: string) {
        let values: (string | number | null)[] = [];
        return {
          bind(...args: (string | number | null)[]) {
            values = args;
            return this;
          },
          async first() {
            return sqlite.prepare(sql).get(...values) ?? null;
          },
          async all() {
            return { results: sqlite.prepare(sql).all(...values) };
          },
        };
      },
    };

    const response = await handleGetHomeReadModel(
      new Request("https://conclave.test/api/home"),
      { CONCLAVE_DB: db } as unknown as Parameters<
        typeof handleGetHomeReadModel
      >[1],
    );

    expect(response.status).toBe(200);
    const data = (await response.json()) as {
      attention: Array<Record<string, unknown>>;
      running: Array<Record<string, unknown>>;
      recentWork: Array<Record<string, unknown>>;
      productUpdates: Array<Record<string, unknown>>;
      aiUpdates: Array<Record<string, unknown>>;
    };

    // 1. Structure
    expect(Array.isArray(data.attention)).toBe(true);
    expect(Array.isArray(data.running)).toBe(true);
    expect(Array.isArray(data.recentWork)).toBe(true);
    expect(Array.isArray(data.productUpdates)).toBe(true);
    expect(Array.isArray(data.aiUpdates)).toBe(true);

    // 2. Attention contains Invitation & Failed Execution
    expect(
      data.attention.some(
        (it) =>
          it.type === "project_invitation" &&
          String(it.title).includes("Julia"),
      ),
    ).toBe(true);
    expect(
      data.attention.some(
        (it) => it.type === "execution_failed" && it.projectId === "proj-auth",
      ),
    ).toBe(true);
    expect(data.attention.some((it) => it.projectId === "proj-revoked")).toBe(
      false,
    );

    // 3. Running contains authorized active run and excludes revoked project run
    expect(data.running).toHaveLength(1);
    expect(data.running[0]).toMatchObject({
      id: "run-active",
      projectId: "proj-auth",
      status: "running",
      objective: "Building Home API projection",
    });

    // 4. Recent Work contains Core Architecture and snippet, and excludes revoked project workstream
    expect(data.recentWork).toHaveLength(1);
    expect(data.recentWork[0]).toMatchObject({
      projectId: "proj-auth",
      workstreamId: "ws-auth",
      workstreamTitle: "Core Architecture",
      lastMessageSnippet: "Home read model projection complete.",
    });

    // 5. Product & AI Updates are present
    expect(data.productUpdates.length).toBeGreaterThan(0);
    expect(data.aiUpdates.length).toBeGreaterThan(0);
  } finally {
    sqlite.close();
  }
});
