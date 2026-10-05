import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { workspaceGrantScopeAlignmentSql } from "./align-workspace-grant-schema.mjs";

it("removes only obsolete scope while retaining rows, references and grant protections", () => {
  const db = new DatabaseSync(":memory:");
  const baseline = readFileSync(
    new URL(
      "../apps/cloud/migrations-v8/0001_conclave_v8.sql",
      import.meta.url,
    ),
    "utf8",
  );
  try {
    db.exec(`PRAGMA foreign_keys=ON;
      CREATE TABLE workspace_project_grants (id TEXT PRIMARY KEY, status TEXT NOT NULL,
        scope TEXT NOT NULL CHECK(scope IN ('project_repository', 'selected_paths', 'full_workspace')),
        allowed_permissions_json TEXT NOT NULL DEFAULT '[]');
      CREATE TABLE assignments (grant_id TEXT REFERENCES workspace_project_grants(id));
      CREATE INDEX grant_status ON workspace_project_grants(status);
      CREATE TRIGGER retain_revoked BEFORE UPDATE OF status ON workspace_project_grants
        WHEN OLD.status='revoked' BEGIN SELECT RAISE(ABORT, 'revoked'); END;
      INSERT INTO workspace_project_grants VALUES ('old-grant', 'revoked', 'project_repository', '["workstream.read"]');
      INSERT INTO assignments VALUES ('old-grant');`);
    expect(() =>
      db.exec(
        "INSERT INTO workspace_project_grants(id,status) VALUES('new-grant','active')",
      ),
    ).toThrow(/scope/);
    db.exec(workspaceGrantScopeAlignmentSql(baseline));
    db.exec(
      "INSERT INTO workspace_project_grants(id,status) VALUES('new-grant','active')",
    );
    expect(
      db
        .prepare("SELECT * FROM workspace_project_grants WHERE id='old-grant'")
        .get(),
    ).toEqual({
      id: "old-grant",
      status: "revoked",
      allowed_permissions_json: '["workstream.read"]',
    });
    expect(db.prepare("SELECT * FROM assignments").all()).toEqual([
      { grant_id: "old-grant" },
    ]);
    expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
    expect(() =>
      db.exec(
        "UPDATE workspace_project_grants SET status='active' WHERE id='old-grant'",
      ),
    ).toThrow(/revoked/);
    expect(
      db
        .prepare("SELECT name FROM sqlite_master WHERE name='grant_status'")
        .get(),
    ).toBeTruthy();
  } finally {
    db.close();
  }
});
