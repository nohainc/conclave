import { describe, expect, it } from "vitest";
import { DatabaseSync } from "node:sqlite";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const migrationPath = path.resolve(
  __dirname,
  "../../../apps/cloud/migrations-v5/0001_conclave_v5.sql",
);

function createDb(): DatabaseSync {
  const db = new DatabaseSync(":memory:");
  db.exec(fs.readFileSync(migrationPath, "utf8"));
  return db;
}

function insertUser(db: DatabaseSync, id: string): void {
  db.prepare(
    "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, 'now', 'now')",
  ).run(id, `${id}@example.com`, id);
}

function insertProject(
  db: DatabaseSync,
  id: string,
  ownerUserId: string,
): void {
  db.prepare(
    "INSERT INTO projects (id, owner_user_id, name, created_at, updated_at) VALUES (?, ?, ?, 'now', 'now')",
  ).run(id, ownerUserId, id);
  db.prepare(
    "INSERT INTO project_memberships (id, project_id, user_id, role, created_at, updated_at) VALUES (?, ?, ?, 'owner', 'now', 'now')",
  ).run(`${id}-owner`, id, ownerUserId);
}

function insertWorkspace(
  db: DatabaseSync,
  id: string,
  ownerUserId: string,
): void {
  db.prepare(
    "INSERT INTO execution_workspaces (id, owner_user_id, name, created_at, updated_at) VALUES (?, ?, ?, 'now', 'now')",
  ).run(id, ownerUserId, id);
}

describe("Architecture v5 clean D1 schema", () => {
  it("applies cleanly and removes collaborative v4 tables", () => {
    const db = createDb();
    const tables = (
      db
        .prepare(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
        )
        .all() as { name: string }[]
    ).map((row) => row.name);

    for (const table of [
      "projects",
      "project_memberships",
      "project_invitations",
      "execution_workspaces",
      "workspace_runtime_identities",
      "workspace_sessions",
      "workspace_enrollments",
      "workspace_releases",
      "workspace_worker_installations",
      "workspace_worker_desired_state",
      "workspace_project_grants",
      "ai_accounts",
      "project_account_grants",
      "worker_assignments",
      "usage",
    ]) {
      expect(tables).toContain(table);
    }
    for (const obsolete of [
      "workspaces",
      "workspace_memberships",
      "workspace_invitations",
      "hosts",
    ]) {
      expect(tables).not.toContain(obsolete);
    }

    const objects = db
      .prepare(
        "SELECT type FROM sqlite_master WHERE type IN ('trigger', 'view')",
      )
      .all();
    expect(objects).toHaveLength(0);
  });

  it("enforces foreign keys and owner deletion rules", () => {
    const db = createDb();
    insertUser(db, "user-owner");
    insertUser(db, "user-member");
    insertProject(db, "project-a", "user-owner");
    insertWorkspace(db, "workspace-a", "user-owner");

    db.prepare(
      "INSERT INTO project_memberships (id, project_id, user_id, role, created_at, updated_at) VALUES ('membership-a', 'project-a', 'user-member', 'collaborator', 'now', 'now')",
    ).run();
    expect(() =>
      db
        .prepare(
          "INSERT INTO project_memberships (id, project_id, user_id, role, created_at, updated_at) VALUES ('bad', 'missing-project', 'user-member', 'viewer', 'now', 'now')",
        )
        .run(),
    ).toThrow(/FOREIGN KEY/);
    expect(() =>
      db.prepare("DELETE FROM users WHERE id = 'user-owner'").run(),
    ).toThrow(/FOREIGN KEY/);

    db.prepare("DELETE FROM users WHERE id = 'user-member'").run();
    expect(
      (
        db
          .prepare(
            "SELECT COUNT(*) AS count FROM project_memberships WHERE user_id = 'user-member'",
          )
          .get() as { count: number }
      ).count,
    ).toBe(0);
  });

  it("isolates Project membership from execution Workspace grants", () => {
    const db = createDb();
    insertUser(db, "user-owner");
    insertUser(db, "user-other");
    insertProject(db, "project-a", "user-owner");
    insertWorkspace(db, "workspace-a", "user-owner");
    db.prepare(
      "INSERT INTO project_memberships (id, project_id, user_id, role, created_at, updated_at) VALUES ('membership-other', 'project-a', 'user-other', 'collaborator', 'now', 'now')",
    ).run();

    expect(() =>
      db
        .prepare(
          `INSERT INTO workspace_project_grants
            (id, project_id, workspace_id, granted_by_user_id, scope, created_at, updated_at)
           VALUES ('grant-a', 'project-a', 'workspace-a', 'user-other', 'project_repository', 'now', 'now')`,
        )
        .run(),
    ).toThrow(/FOREIGN KEY/);

    db.prepare(
      `INSERT INTO workspace_project_grants
        (id, project_id, workspace_id, granted_by_user_id, scope, created_at, updated_at)
       VALUES ('grant-a', 'project-a', 'workspace-a', 'user-owner', 'project_repository', 'now', 'now')`,
    ).run();
    expect(
      (
        db
          .prepare(
            "SELECT project_id FROM workspace_project_grants WHERE id = 'grant-a'",
          )
          .get() as { project_id: string }
      ).project_id,
    ).toBe("project-a");
  });

  it("isolates AI Accounts and Project Account Grants", () => {
    const db = createDb();
    insertUser(db, "user-owner");
    insertUser(db, "user-other");
    insertProject(db, "project-a", "user-owner");
    insertProject(db, "project-b", "user-other");
    db.prepare(
      "INSERT INTO workers (id, display_name, publisher, status, created_at, updated_at) VALUES ('worker-a', 'Worker A', 'Conclave', 'active', 'now', 'now')",
    ).run();
    db.prepare(
      "INSERT INTO ai_accounts (id, owner_user_id, worker_id, display_name, auth_type, secret_location, secret_reference, status, created_at, updated_at) VALUES ('account-a', 'user-owner', 'worker-a', 'Owner Account', 'api_key', 'workspace_secure_store', 'workspace-secret/account-a', 'ready', 'now', 'now')",
    ).run();

    db.prepare(
      "INSERT INTO project_account_grants (id, project_id, account_id, granted_by_user_id, grantee_user_id, created_at) VALUES ('account-grant-a', 'project-a', 'account-a', 'user-owner', 'user-owner', 'now')",
    ).run();
    expect(() =>
      db
        .prepare(
          "INSERT INTO project_account_grants (id, project_id, account_id, granted_by_user_id, grantee_user_id, created_at) VALUES ('account-grant-b', 'project-b', 'missing-account', 'user-other', 'user-other', 'now')",
        )
        .run(),
    ).toThrow(/FOREIGN KEY/);
    expect(() =>
      db.prepare("DELETE FROM users WHERE id = 'user-owner'").run(),
    ).toThrow(/FOREIGN KEY/);
    expect(
      (
        db
          .prepare(
            "SELECT secret_reference FROM ai_accounts WHERE id = 'account-a'",
          )
          .get() as { secret_reference: string }
      ).secret_reference,
    ).toBe("workspace-secret/account-a");
  });

  it("keeps project-scoped history free of execution Workspace foreign keys", () => {
    const db = createDb();
    for (const table of [
      "chats",
      "goals",
      "runs",
      "artifacts",
      "findings",
      "events",
      "usage",
    ]) {
      const columns = db.prepare(`PRAGMA table_info(${table})`).all() as {
        name: string;
      }[];
      expect(columns.map((column) => column.name)).not.toContain(
        "workspace_id",
      );
      expect(columns.map((column) => column.name)).not.toContain(
        "workspace_membership_id",
      );
    }
  });

  it("supports the clean-room solo, collaboration, and multi-owner paths", () => {
    const db = createDb();
    insertUser(db, "owner");
    insertUser(db, "collaborator");
    insertUser(db, "other-owner");
    insertProject(db, "project", "owner");
    insertWorkspace(db, "owner-workspace", "owner");
    insertWorkspace(db, "contributor-workspace", "collaborator");

    db.prepare(
      "INSERT INTO project_memberships (id, project_id, user_id, role, created_at, updated_at) VALUES ('collab-membership', 'project', 'collaborator', 'collaborator', 'now', 'now')",
    ).run();
    db.prepare(
      `INSERT INTO workspace_project_grants
        (id, project_id, workspace_id, granted_by_user_id, status, scope, created_at, updated_at)
       VALUES ('owner-grant', 'project', 'owner-workspace', 'owner', 'active', 'project_repository', 'now', 'now'),
              ('contributor-grant', 'project', 'contributor-workspace', 'collaborator', 'active', 'selected_paths', 'now', 'now')`,
    ).run();

    // Project membership and Workspace access are separate boundaries.
    expect(
      (
        db
          .prepare(
            "SELECT owner_user_id FROM execution_workspaces WHERE id = 'owner-workspace'",
          )
          .get() as { owner_user_id: string }
      ).owner_user_id,
    ).toBe("owner");
    expect(
      (
        db
          .prepare(
            "SELECT COUNT(*) AS count FROM workspace_project_grants WHERE project_id = 'project' AND status = 'active'",
          )
          .get() as { count: number }
      ).count,
    ).toBe(2);

    // The recommended membership-removal policy revokes contributed capacity.
    db.prepare(
      `DELETE FROM project_memberships WHERE project_id = 'project' AND user_id = 'collaborator'`,
    ).run();
    db.prepare(
      `UPDATE workspace_project_grants
          SET status = 'revoked', updated_at = 'now'
        WHERE project_id = 'project' AND granted_by_user_id = 'collaborator' AND status = 'active'`,
    ).run();
    expect(
      (
        db
          .prepare(
            "SELECT status FROM workspace_project_grants WHERE id = 'contributor-grant'",
          )
          .get() as { status: string }
      ).status,
    ).toBe("revoked");
    expect(
      (
        db
          .prepare(
            "SELECT COUNT(*) AS count FROM project_memberships WHERE project_id = 'project' AND user_id = 'collaborator'",
          )
          .get() as { count: number }
      ).count,
    ).toBe(0);
  });
});
