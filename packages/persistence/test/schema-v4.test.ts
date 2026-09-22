import { describe, expect, it } from "vitest";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const migrationPath = path.resolve(
  __dirname,
  "../../../apps/worker/migrations-v4/0001_conclave_v4.sql",
);
const seedPath = path.resolve(
  __dirname,
  "../../../apps/worker/seed/v4-development.sql",
);

function createDb(): DatabaseSync {
  const db = new DatabaseSync(":memory:");
  db.exec("PRAGMA foreign_keys = ON;");
  db.exec(fs.readFileSync(migrationPath, "utf8"));
  return db;
}

function seedTenant(db: DatabaseSync, workspaceId: string, userId: string) {
  db.prepare(
    "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
  ).run(userId, `${userId}@example.com`, userId, "now", "now");
  db.prepare(
    "INSERT INTO workspaces (id, name, slug, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
  ).run(workspaceId, workspaceId, workspaceId, "now", "now");
  db.prepare(
    "INSERT INTO workspace_memberships (id, workspace_id, user_id, role, created_at, updated_at) VALUES (?, ?, ?, 'owner', ?, ?)",
  ).run(`${workspaceId}-membership`, workspaceId, userId, "now", "now");
}

describe("Architecture v4 clean D1 schema", () => {
  it("applies cleanly and contains no v3 fleet or secret tables", () => {
    const db = createDb();
    const names = (
      db
        .prepare(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
        )
        .all() as { name: string }[]
    ).map((row) => row.name);

    for (const table of [
      "hosts",
      "host_workspace_bindings",
      "host_enrollments",
      "host_sessions",
      "host_releases",
      "workers",
      "worker_versions",
      "host_worker_installations",
      "credential_profiles",
      "credential_grants",
      "worker_assignments",
      "project_execution_preferences",
      "user_execution_preferences",
    ]) {
      expect(names).toContain(table);
    }
    for (const obsolete of [
      "agents",
      "agent_enrollments",
      "agent_sessions",
      "agent_releases",
      "worker_plugins",
      "worker_plugin_versions",
      "agent_plugin_installs",
      "credentials",
      "extensions",
    ]) {
      expect(names).not.toContain(obsolete);
    }
  });

  it("enforces foreign keys and allows one Host to bind multiple Workspaces", () => {
    const db = createDb();
    seedTenant(db, "ws-a", "user-a");
    seedTenant(db, "ws-b", "user-b");
    db.prepare(
      "INSERT INTO hosts (id, name, hostname, status, version, enrolled_at, created_at, updated_at) VALUES ('host-1', 'Host', 'host.local', 'online', '4.0.0', 'now', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO host_workspace_bindings (id, host_id, workspace_id, granted_by_user_id, created_at, updated_at) VALUES ('binding-a', 'host-1', 'ws-a', 'user-a', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO host_workspace_bindings (id, host_id, workspace_id, granted_by_user_id, created_at, updated_at) VALUES ('binding-b', 'host-1', 'ws-b', 'user-b', 'now', 'now')",
    ).run();
    expect(
      (
        db
          .prepare(
            "SELECT COUNT(*) AS count FROM host_workspace_bindings WHERE host_id = 'host-1'",
          )
          .get() as { count: number }
      ).count,
    ).toBe(2);
    expect(() =>
      db
        .prepare(
          "INSERT INTO host_workspace_bindings (id, host_id, workspace_id, created_at, updated_at) VALUES ('invalid', 'missing-host', 'ws-a', 'now', 'now')",
        )
        .run(),
    ).toThrow(/FOREIGN KEY/);
  });

  it("enforces credential grants without storing raw secrets", () => {
    const db = createDb();
    seedTenant(db, "ws-a", "user-a");
    db.prepare(
      "INSERT INTO workers (id, display_name, publisher, status, created_at, updated_at) VALUES ('codex', 'Codex', 'Conclave', 'active', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO hosts (id, name, hostname, status, version, enrolled_at, created_at, updated_at) VALUES ('host-a', 'Host', 'host.local', 'online', '4.0.0', 'now', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO host_workspace_bindings (id, host_id, workspace_id, created_at, updated_at) VALUES ('binding-a', 'host-a', 'ws-a', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO credential_profiles (id, workspace_id, owner_type, owner_id, worker_id, host_id, display_name, auth_type, secret_location, secret_reference, status, sharing_policy, provider_metadata_json, created_at, updated_at) VALUES ('cred-a', 'ws-a', 'user', 'user-a', 'codex', 'host-a', 'Vitalii Codex', 'oauth_browser', 'host_secure_store', 'credential-profile/host-a/codex/cred-a', 'ready', 'owner_controlled', '{}', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO credential_grants (id, credential_profile_id, workspace_id, grantee_type, grantee_id, granted_by_user_id, created_at) VALUES ('grant-a', 'cred-a', 'ws-a', 'user', 'user-a', 'user-a', 'now')",
    ).run();
    const columns = db
      .prepare("PRAGMA table_info(credential_profiles)")
      .all() as { name: string }[];
    expect(columns.map((column) => column.name)).not.toContain("secret");
    expect(
      (
        db
          .prepare(
            "SELECT secret_reference FROM credential_profiles WHERE id = 'cred-a'",
          )
          .get() as { secret_reference: string }
      ).secret_reference,
    ).toBe("credential-profile/host-a/codex/cred-a");

    const grantColumns = db
      .prepare("PRAGMA table_info(credential_grants)")
      .all() as { name: string }[];
    expect(grantColumns.map((column) => column.name)).toEqual(
      expect.arrayContaining([
        "use_permission",
        "expires_at",
        "usage_limit",
        "revoked_at",
      ]),
    );
  });

  it("keeps usage attribution separate from credential secrets", () => {
    const db = createDb();
    const usageColumns = db.prepare("PRAGMA table_info(usage)").all() as {
      name: string;
    }[];
    expect(usageColumns.map((column) => column.name)).toEqual(
      expect.arrayContaining([
        "credential_profile_id",
        "requester_user_id",
        "host_id",
        "worker_id",
        "model",
        "input_tokens",
        "output_tokens",
        "cost_micros",
        "duration_ms",
      ]),
    );
    expect(usageColumns.map((column) => column.name)).not.toContain("secret");
  });

  it("reconstructs a v4 assignment from its immutable execution snapshot", () => {
    const db = createDb();
    seedTenant(db, "ws-a", "user-a");
    db.prepare(
      "INSERT INTO projects (id, workspace_id, name, created_at, updated_at) VALUES ('project-a', 'ws-a', 'Project', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO goals (id, workspace_id, project_id, original_message, objective, status, created_at, updated_at) VALUES ('goal-a', 'ws-a', 'project-a', 'message', 'objective', 'running', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO runs (id, workspace_id, project_id, goal_id, policy_snapshot_json, status, created_at, updated_at) VALUES ('run-a', 'ws-a', 'project-a', 'goal-a', '{}', 'running', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO phases (id, run_id, name, purpose, sequence, status, created_at, updated_at) VALUES ('phase-a', 'run-a', 'Phase', 'Purpose', 1, 'running', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO tasks (id, phase_id, objective, role, status, created_at, updated_at) VALUES ('task-a', 'phase-a', 'Objective', 'implementation', 'running', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO hosts (id, name, hostname, status, version, enrolled_at, created_at, updated_at) VALUES ('host-a', 'Host', 'host.local', 'online', '4.0.0', 'now', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO host_workspace_bindings (id, host_id, workspace_id, granted_by_user_id, created_at, updated_at) VALUES ('binding-a', 'host-a', 'ws-a', 'user-a', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO workers (id, display_name, publisher, status, created_at, updated_at) VALUES ('codex', 'Codex', 'Conclave', 'active', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO credential_profiles (id, workspace_id, owner_type, owner_id, worker_id, display_name, auth_type, secret_location, status, sharing_policy, created_at, updated_at) VALUES ('cred-a', 'ws-a', 'user', 'user-a', 'codex', 'Codex', 'none', 'none', 'ready', 'private_only', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO attempts (id, task_id, worker_id, attempt_number, input_snapshot_json, status, started_at) VALUES ('attempt-a', 'task-a', 'codex', 1, '{}', 'running', 'now')",
    ).run();
    db.prepare(
      `INSERT INTO worker_assignments (id, workspace_id, project_id, run_id, task_id, attempt_id, requested_by_user_id, host_id, worker_id, resolved_worker_version, credential_profile_id, model, config_json, session_policy, permissions_json, context_refs_json, timeout_ms, idempotency_key, status, input_json, created_at, updated_at) VALUES ('assignment-a', 'ws-a', 'project-a', 'run-a', 'task-a', 'attempt-a', 'user-a', 'host-a', 'codex', '1.0.0', 'cred-a', 'codex-1', '{"temperature":0}', 'isolated_workspace', '["fs:read"]', '[{"uri":"repo://project-a"}]', 60000, 'idempotency-a', 'running', '{"objective":"Objective"}', 'now', 'now')`,
    ).run();

    const snapshot = db
      .prepare(
        "SELECT workspace_id, project_id, run_id, task_id, host_id, worker_id, resolved_worker_version, credential_profile_id, model, config_json, session_policy, permissions_json, context_refs_json, timeout_ms, idempotency_key FROM worker_assignments WHERE id = 'assignment-a'",
      )
      .get() as Record<string, unknown>;
    expect(snapshot).toMatchObject({
      workspace_id: "ws-a",
      project_id: "project-a",
      host_id: "host-a",
      worker_id: "codex",
      credential_profile_id: "cred-a",
      idempotency_key: "idempotency-a",
    });
    expect(snapshot.config_json).toBe('{"temperature":0}');
  });

  it("applies the clean development seed with catalog workers only", () => {
    const db = createDb();
    db.exec(fs.readFileSync(seedPath, "utf8"));
    expect(
      (
        db.prepare("SELECT COUNT(*) AS count FROM workers").get() as {
          count: number;
        }
      ).count,
    ).toBe(3);
    expect(
      (
        db.prepare("SELECT COUNT(*) AS count FROM users").get() as {
          count: number;
        }
      ).count,
    ).toBe(0);
    expect(
      (
        db
          .prepare("SELECT COUNT(*) AS count FROM credential_profiles")
          .get() as { count: number }
      ).count,
    ).toBe(0);
  });
});
