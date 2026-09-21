import { describe, expect, it } from "vitest";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const schemaPath = path.resolve(
  __dirname,
  "../../../apps/worker/migrations/0001_initial.sql",
);

describe("Architecture v2 Clean D1 Schema Baseline", () => {
  function createTestDb(): DatabaseSync {
    const db = new DatabaseSync(":memory:");
    db.exec("PRAGMA foreign_keys = ON;");
    const sql = fs.readFileSync(schemaPath, "utf8");
    db.exec(sql);
    return db;
  }

  it("applies migration cleanly without errors", () => {
    const db = createTestDb();
    const rows = db
      .prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      )
      .all() as { name: string }[];
    const tableNames = rows.map((r) => r.name);

    expect(tableNames).toContain("users");
    expect(tableNames).toContain("auth_sessions");
    expect(tableNames).toContain("workspaces");
    expect(tableNames).toContain("workspace_memberships");
    expect(tableNames).toContain("projects");
    expect(tableNames).toContain("project_memberships");
    expect(tableNames).toContain("chats");
    expect(tableNames).toContain("chat_messages");
    expect(tableNames).toContain("goals");
    expect(tableNames).toContain("runs");
    expect(tableNames).toContain("phases");
    expect(tableNames).toContain("tasks");
    expect(tableNames).toContain("task_dependencies");
    expect(tableNames).toContain("attempts");
    expect(tableNames).toContain("completion_criteria");
    expect(tableNames).toContain("agents");
    expect(tableNames).toContain("agent_enrollments");
    expect(tableNames).toContain("agent_sessions");
    expect(tableNames).toContain("agent_releases");
    expect(tableNames).toContain("worker_plugins");
    expect(tableNames).toContain("worker_plugin_versions");
    expect(tableNames).toContain("agent_plugin_installs");
    expect(tableNames).toContain("workers");
    expect(tableNames).toContain("worker_assignments");
    expect(tableNames).toContain("artifacts");
    expect(tableNames).toContain("findings");
    expect(tableNames).toContain("verifications");
    expect(tableNames).toContain("events");
    expect(tableNames).toContain("budgets");
    expect(tableNames).toContain("usage");
    expect(tableNames).toContain("audit_log");
    expect(tableNames).toContain("ci_evidence");

    // Confirms obsolete connection tables are absent
    expect(tableNames).not.toContain("connections");
    expect(tableNames).not.toContain("worker_connections");
  });

  it("enforces foreign key cascading deletions from Workspace down to Fleet and Runs", () => {
    const db = createTestDb();

    // 1. Create user and workspace
    db.prepare(
      "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES ('u1', 'u@test.com', 'User 1', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO workspaces (id, name, slug, created_at, updated_at) VALUES ('ws1', 'Workspace 1', 'ws-1', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO workspace_memberships (id, workspace_id, user_id, role, created_at, updated_at) VALUES ('wm1', 'ws1', 'u1', 'owner', 'now', 'now')",
    ).run();

    // 2. Create agent and plugin
    db.prepare(
      "INSERT INTO agents (id, workspace_id, name, hostname, status, version, enrolled_at, created_at, updated_at) VALUES ('ag1', 'ws1', 'Agent 1', 'host1', 'online', '2.0.0', 'now', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO worker_plugins (id, display_name, description, publisher, status, created_at, updated_at) VALUES ('p-codex', 'Codex', 'Codex plugin', 'official', 'active', 'now', 'now')",
    ).run();

    // 3. Create worker
    db.prepare(
      "INSERT INTO workers (id, workspace_id, agent_id, plugin_id, name, billing_mode, independence_key, created_at, updated_at) VALUES ('w1', 'ws1', 'ag1', 'p-codex', 'Worker 1', 'subscription', 'ind-1', 'now', 'now')",
    ).run();

    // 4. Create project, goal, run, phase, task, attempt, assignment
    db.prepare(
      "INSERT INTO projects (id, workspace_id, name, created_at, updated_at) VALUES ('proj1', 'ws1', 'Project 1', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO goals (id, workspace_id, project_id, original_message, objective, status, created_at, updated_at) VALUES ('g1', 'ws1', 'proj1', 'msg', 'obj', 'running', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO runs (id, workspace_id, project_id, goal_id, policy_snapshot_json, status, created_at, updated_at) VALUES ('r1', 'ws1', 'proj1', 'g1', '{}', 'running', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO phases (id, run_id, name, purpose, sequence, status, created_at, updated_at) VALUES ('ph1', 'r1', 'Phase 1', 'purpose', 1, 'running', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO tasks (id, phase_id, objective, role, status, created_at, updated_at) VALUES ('t1', 'ph1', 'Task 1', 'implementer', 'running', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO attempts (id, task_id, worker_id, attempt_number, input_snapshot_json, status, started_at) VALUES ('att1', 't1', 'w1', 1, '{}', 'running', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO worker_assignments (id, workspace_id, run_id, task_id, attempt_id, agent_id, worker_id, plugin_id, status, input_json, idempotency_key, created_at, updated_at) VALUES ('asgn1', 'ws1', 'r1', 't1', 'att1', 'ag1', 'w1', 'p-codex', 'dispatched', '{}', 'idemp-1', 'now', 'now')",
    ).run();

    // Verify records exist
    const assignmentBefore = db
      .prepare("SELECT * FROM worker_assignments WHERE id = 'asgn1'")
      .all();
    expect(assignmentBefore.length).toBe(1);

    // Cascade delete workspace
    db.prepare("DELETE FROM workspaces WHERE id = 'ws1'").run();

    // Verify cascaded deletion
    expect(
      db.prepare("SELECT * FROM agents WHERE id = 'ag1'").all().length,
    ).toBe(0);
    expect(
      db.prepare("SELECT * FROM workers WHERE id = 'w1'").all().length,
    ).toBe(0);
    expect(
      db.prepare("SELECT * FROM projects WHERE id = 'proj1'").all().length,
    ).toBe(0);
    expect(db.prepare("SELECT * FROM goals WHERE id = 'g1'").all().length).toBe(
      0,
    );
    expect(db.prepare("SELECT * FROM runs WHERE id = 'r1'").all().length).toBe(
      0,
    );
    expect(db.prepare("SELECT * FROM tasks WHERE id = 't1'").all().length).toBe(
      0,
    );
    expect(
      db.prepare("SELECT * FROM worker_assignments WHERE id = 'asgn1'").all()
        .length,
    ).toBe(0);
  });

  it("enforces unique and check constraints", () => {
    const db = createTestDb();

    db.prepare(
      "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES ('u1', 'u@test.com', 'User 1', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO workspaces (id, name, slug, created_at, updated_at) VALUES ('ws1', 'Workspace 1', 'ws-1', 'now', 'now')",
    ).run();

    // Rejects duplicate email
    expect(() =>
      db
        .prepare(
          "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES ('u2', 'u@test.com', 'User 2', 'now', 'now')",
        )
        .run(),
    ).toThrow(/UNIQUE constraint/);

    // Rejects invalid membership role
    expect(() =>
      db
        .prepare(
          "INSERT INTO workspace_memberships (id, workspace_id, user_id, role, created_at, updated_at) VALUES ('wm1', 'ws1', 'u1', 'invalid_role', 'now', 'now')",
        )
        .run(),
    ).toThrow(/CHECK constraint/);

    // Rejects invalid client_type in auth_sessions
    expect(() =>
      db
        .prepare(
          "INSERT INTO auth_sessions (id, user_id, token_hash, client_type, expires_at, created_at, updated_at) VALUES ('s1', 'u1', 'hash1', 'invalid_client', 'now', 'now', 'now')",
        )
        .run(),
    ).toThrow(/CHECK constraint/);

    // Rejects invalid release channel in worker_plugin_versions
    db.prepare(
      "INSERT INTO worker_plugins (id, display_name, description, publisher, status, created_at, updated_at) VALUES ('p1', 'Plugin', 'Desc', 'pub', 'active', 'now', 'now')",
    ).run();

    expect(() =>
      db
        .prepare(
          "INSERT INTO worker_plugin_versions (id, plugin_id, version, channel, protocol_version, min_agent_version, supported_os_json, supported_arch_json, package_digest, package_r2_key, signature, created_at) VALUES ('pv1', 'p1', '1.0.0', 'invalid_channel', '2.0', '1.0.0', '[]', '[]', 'd1', 'k1', 's1', 'now')",
        )
        .run(),
    ).toThrow(/CHECK constraint/);

    // Accepts valid channel (stable, beta, development) and revocation
    db.prepare(
      "INSERT INTO worker_plugin_versions (id, plugin_id, version, channel, protocol_version, min_agent_version, supported_os_json, supported_arch_json, package_digest, package_r2_key, signature, is_revoked, revoked_at, revocation_reason, created_at) VALUES ('pv1', 'p1', '1.0.0', 'beta', '2.0', '1.0.0', '[]', '[]', 'd1', 'k1', 's1', 1, '2026-09-21T00:00:00Z', 'Security issue', 'now')",
    ).run();

    const row = db
      .prepare("SELECT * FROM worker_plugin_versions WHERE id = 'pv1'")
      .get() as {
      channel: string;
      is_revoked: number;
      revocation_reason: string;
    };
    expect(row.channel).toBe("beta");
    expect(row.is_revoked).toBe(1);
    expect(row.revocation_reason).toBe("Security issue");
  });
});
