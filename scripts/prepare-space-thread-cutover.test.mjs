import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import { spaceThreadCutoverSql } from "./prepare-space-thread-cutover.mjs";
import { assertSpaceThreadSchema } from "./space-thread-schema-preflight.mjs";
const objects = (db) =>
  db
    .prepare(
      "SELECT type,name,tbl_name,sql FROM sqlite_schema WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY type,name",
    )
    .all();
function apply(db, sql) {
  db.exec("BEGIN");
  try {
    db.exec(sql);
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}
function fixture() {
  const db = new DatabaseSync(":memory:");
  db.exec(`PRAGMA foreign_keys=ON;
 CREATE TABLE users(id TEXT PRIMARY KEY, secret TEXT);
 CREATE TABLE projects(id TEXT PRIMARY KEY, owner_user_id TEXT REFERENCES users(id), name TEXT);
 CREATE TABLE project_memberships(id TEXT PRIMARY KEY, project_id TEXT REFERENCES projects(id), user_id TEXT REFERENCES users(id));
 CREATE TABLE project_invitations(id TEXT PRIMARY KEY, project_id TEXT REFERENCES projects(id), token_hash TEXT);
 CREATE TABLE workspace_project_grants(id TEXT PRIMARY KEY, project_id TEXT REFERENCES projects(id));
 CREATE TABLE workstreams(id TEXT PRIMARY KEY, project_id TEXT REFERENCES projects(id), name TEXT);
 CREATE TABLE work_requests(id TEXT PRIMARY KEY, workstream_id TEXT REFERENCES workstreams(id), input_json TEXT, snapshot_json TEXT);
 CREATE TABLE realtime_events(event_id TEXT PRIMARY KEY, stream_kind TEXT CHECK(stream_kind IN ('project','user')), project_id TEXT REFERENCES projects(id), workstream_id TEXT REFERENCES workstreams(id), event_type TEXT, payload_json TEXT);
 CREATE INDEX idx_old_events ON realtime_events(project_id);
 CREATE TABLE signed_profiles(id TEXT PRIMARY KEY, profile_json TEXT, signature TEXT);
 INSERT INTO users VALUES('U','unchanged-secret');
 INSERT INTO projects VALUES('P','U','My Project title');
 INSERT INTO project_memberships VALUES('M','P','U');
 INSERT INTO project_invitations VALUES('I','P','unchanged-token-hash');
 INSERT INTO workspace_project_grants VALUES('G','P');
 INSERT INTO workstreams VALUES('T','P','Existing Thread');
 INSERT INTO signed_profiles VALUES('S','{"projectId":"signed-original"}','unchanged-signature');`);
  db.prepare("INSERT INTO work_requests VALUES(?,?,?,?)").run(
    "W",
    "T",
    JSON.stringify({
      prompt: 'Please retain the word project and "projectId": in my text',
      nested: { projectId: "P", workstreamId: "T" },
      scope: { kind: "project" },
    }),
    JSON.stringify({ workspaceProjectGrantId: "G" }),
  );
  db.prepare("INSERT INTO realtime_events VALUES(?,?,?,?,?,?)").run(
    "E",
    "project",
    "P",
    "T",
    "workstream.completed",
    JSON.stringify({ workstreamId: "T", projectId: "P" }),
  );
  return db;
}
it("preserves IDs, references, user text, credentials and signed profiles while converting runtime metadata", () => {
  const db = fixture();
  try {
    apply(db, spaceThreadCutoverSql(objects(db)));
    assertSpaceThreadSchema([{ success: true, results: objects(db) }]);
    expect(db.prepare("SELECT name FROM spaces").get().name).toBe(
      "My Project title",
    );
    expect(db.prepare("SELECT space_id FROM threads").get().space_id).toBe("P");
    expect(
      db.prepare("SELECT token_hash FROM space_invitations").get().token_hash,
    ).toBe("unchanged-token-hash");
    expect(db.prepare("SELECT secret FROM users").get().secret).toBe(
      "unchanged-secret",
    );
    const row = db
      .prepare("SELECT input_json,snapshot_json FROM work_requests")
      .get();
    expect(JSON.parse(row.input_json)).toEqual({
      prompt: 'Please retain the word project and "projectId": in my text',
      nested: { spaceId: "P", threadId: "T" },
      scope: { kind: "space" },
    });
    expect(JSON.parse(row.snapshot_json)).toEqual({
      workspaceSpaceGrantId: "G",
    });
    expect(
      db.prepare("SELECT stream_kind,event_type FROM realtime_events").get(),
    ).toEqual({ stream_kind: "space", event_type: "thread.completed" });
    expect(
      db.prepare("SELECT profile_json,signature FROM signed_profiles").get(),
    ).toEqual({
      profile_json: '{"projectId":"signed-original"}',
      signature: "unchanged-signature",
    });
    expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
    expect(
      db
        .prepare("SELECT name FROM sqlite_schema WHERE name LIKE '__cutover_%'")
        .all(),
    ).toEqual([]);
  } finally {
    db.close();
  }
});
it("rolls back ambiguous metadata and rejects schema drift before mutation", () => {
  const db = fixture();
  try {
    const sql = spaceThreadCutoverSql(objects(db));
    db.prepare("UPDATE work_requests SET input_json=?").run(
      '{"projectId":"P","spaceId":"different"}',
    );
    expect(() => apply(db, sql)).toThrow();
    expect(db.prepare("SELECT COUNT(*) AS n FROM projects").get().n).toBe(1);
    db.exec("ALTER TABLE projects ADD COLUMN changed TEXT");
    expect(() => apply(db, sql)).toThrow();
    expect(db.prepare("SELECT COUNT(*) AS n FROM projects").get().n).toBe(1);
  } finally {
    db.close();
  }
});
it("rejects mixed schemas rather than overwriting renamed data", () => {
  const db = fixture();
  try {
    db.exec("CREATE TABLE spaces(id TEXT)");
    expect(() => spaceThreadCutoverSql(objects(db))).toThrow(/unmixed/);
  } finally {
    db.close();
  }
});
it("keeps the fresh-start schema separate from operational conversion", () => {
  const baseline = readFileSync(
    new URL(
      "../apps/cloud/migrations-v8/0001_conclave_v8.sql",
      import.meta.url,
    ),
    "utf8",
  );
  expect(baseline).toContain("CREATE TABLE spaces");
  expect(baseline).not.toContain("__cutover_");
});

it("stops atomically when execution is active", () => {
  const db = fixture();
  try {
    db.exec(
      "ALTER TABLE work_requests ADD COLUMN status TEXT DEFAULT 'running'",
    );
    expect(() => apply(db, spaceThreadCutoverSql(objects(db)))).toThrow();
    expect(db.prepare("SELECT COUNT(*) AS n FROM projects").get().n).toBe(1);
  } finally {
    db.close();
  }
});
