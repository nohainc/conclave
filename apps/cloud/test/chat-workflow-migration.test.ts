import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { BUILTIN_WORKFLOW_CATALOG } from "@conclave/core";

const sql = (name: string) =>
  readFileSync(new URL(`../migrations-v8/${name}`, import.meta.url), "utf8");
const migration = sql("0006_chat_workflow_admission.sql");

function apply(db: DatabaseSync, source: string) {
  db.exec("BEGIN");
  try {
    db.exec(source);
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

function database() {
  const db = new DatabaseSync(":memory:");
  db.exec("PRAGMA foreign_keys = ON");
  for (const name of [
    "0001_conclave_v8.sql",
    "0002_desktop_auth_multi_audience.sql",
    "0003_workspace_installations.sql",
    "0004_workspace_runtime_identity_uniqueness.sql",
    "0005_workspace_schema_alignment.sql",
  ])
    apply(db, sql(name));
  db.exec(`
    INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('user','test@example.com','Test','now','now');
    INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('space','user','Space','now','now');
    INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('workspace','user','Workspace','now','now');
    INSERT INTO workspace_runtime_identities(id,workspace_id,credential_token_hash,installation_id,created_at) VALUES('runtime','workspace','hash','installation','now');
    INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('stream','space','Stream','active','user','now','now');
  `);
  const snapshot = JSON.stringify(
    BUILTIN_WORKFLOW_CATALOG["direct:v1"],
    null,
    2,
  );
  db.prepare(
    `INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,primary_workspace_id,input_json,created_at,updated_at,snapshot_json,cancel_requested_at)
    VALUES('request','stream','user','stateful','direct',1,?,'running','workspace',?,'created','updated',?,'cancel-requested')`,
  ).run(
    snapshot,
    '{"originalRequest":"**Keep raw**"}',
    '{ "immutable": true }',
  );
  db.exec(`
    INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,attempt,output_json,error,created_at,updated_at,started_at,finished_at)
      VALUES('task','request','implement','stateful_thread',900000,'implement:v1','completed',2,'{"text":"result"}','error','created','updated','started','finished'),
        ('verify','request','verify','stateless_read',900000,'verify:v1','queued',0,NULL,NULL,'created','updated',NULL,NULL);
    INSERT INTO workflow_task_dependencies VALUES('verify','task');
    INSERT INTO thread_runtime_leases VALUES('lease','stream','request','workspace',4,'active','acquired','expires',NULL);
    INSERT INTO runs(id,space_id,thread_id,work_request_id,status,created_at,updated_at,policy_snapshot_json) VALUES('run','space','stream','request','running','created','updated','{"policy":true}');
    INSERT INTO worker_assignments(id,space_id,run_id,thread_id,work_request_id,execution_workspace_id,runtime_identity_id,worker_type_id,status,created_at,updated_at,task_id,session_policy)
      VALUES('assignment','space','run','stream','request','workspace','runtime','chatgpt','completed','created','updated','task','durable_session');
    INSERT INTO artifacts(id,space_id,run_id,thread_id,work_request_id,assignment_id,content_digest,storage_key,created_at)
      VALUES('artifact','space','run','stream','request','assignment','digest','key','created');
  `);
  return db;
}

describe("Chat schema migration with foreign keys enabled", () => {
  it("preserves populated history, dependencies, leases, cancellation and schema objects", () => {
    const db = database();
    try {
      const tables = [
        "work_requests",
        "workflow_tasks",
        "workflow_task_dependencies",
        "thread_runtime_leases",
        "runs",
        "worker_assignments",
        "artifacts",
      ];
      const before = tables.map((t) => db.prepare(`SELECT * FROM ${t}`).all());
      const objects = db
        .prepare(
          "SELECT name, sql FROM sqlite_schema WHERE type IN ('index','trigger') ORDER BY name",
        )
        .all();
      const foreignKeys = tables.map((t) =>
        db.prepare(`PRAGMA foreign_key_list(${t})`).all(),
      );
      apply(db, migration);
      expect(tables.map((t) => db.prepare(`SELECT * FROM ${t}`).all())).toEqual(
        before,
      );
      expect(
        db
          .prepare(
            "SELECT name, sql FROM sqlite_schema WHERE type IN ('index','trigger') ORDER BY name",
          )
          .all(),
      ).toEqual(objects);
      expect(
        tables.map((t) => db.prepare(`PRAGMA foreign_key_list(${t})`).all()),
      ).toEqual(foreignKeys);
      expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
      expect(db.prepare("PRAGMA foreign_keys").get()).toEqual({
        foreign_keys: 1,
      });
      expect(() =>
        db.exec(
          "UPDATE work_requests SET workflow_snapshot_json = '{}' WHERE id = 'request'",
        ),
      ).toThrow("immutable");
      db.exec(
        "UPDATE work_requests SET cancel_requested_at = 'later' WHERE id = 'request'",
      );
      db.exec(`INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,created_at,updated_at)
        VALUES('chat','stream','user','stateless','chat',1,'{"name":"Chat"}','queued','now','now');
        INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at)
        VALUES('chat-task','chat','chat','stateless_read',900000,'chat:v1','queued','now','now');`);
      expect(() =>
        db.exec(
          "UPDATE workflow_tasks SET step_kind = 'unknown' WHERE id = 'chat-task'",
        ),
      ).toThrow("CHECK");
      expect(() =>
        db.exec(
          "UPDATE workflow_tasks SET work_request_id = 'missing' WHERE id = 'chat-task'",
        ),
      ).toThrow("FOREIGN KEY");
      expect(
        db
          .prepare(
            "SELECT name FROM sqlite_schema WHERE name LIKE '__migration_0006_%'",
          )
          .all(),
      ).toEqual([]);
    } finally {
      db.close();
    }
  });

  it.each([
    "ALTER TABLE work_requests ADD COLUMN future_column TEXT",
    "CREATE INDEX future_index ON workflow_tasks(status)",
    "DROP INDEX idx_workflow_tasks_request; CREATE INDEX idx_workflow_tasks_request ON workflow_tasks(status)",
    "DROP TRIGGER trg_work_requests_snapshot_immutable; CREATE TRIGGER trg_work_requests_snapshot_immutable BEFORE UPDATE ON work_requests BEGIN SELECT RAISE(ABORT, 'custom'); END",
  ])("fails atomically on unrecognized schema additions: %s", (addition) => {
    const db = database();
    try {
      db.exec(addition);
      const before = db.prepare("SELECT * FROM work_requests").all();
      expect(() => apply(db, migration)).toThrow("CHECK");
      expect(db.prepare("SELECT * FROM work_requests").all()).toEqual(before);
      expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
      expect(
        db
          .prepare(
            "SELECT name FROM sqlite_schema WHERE name LIKE '__migration_0006_%'",
          )
          .all(),
      ).toEqual([]);
    } finally {
      db.close();
    }
  });

  it("updates only an unchanged starter and preserves operator templates", () => {
    const db = database();
    try {
      db.exec(
        "UPDATE tool_profile_starter_templates SET profile_json = json_set(profile_json, '$.providerTool.name', 'Operator CLI'), updated_at = 'operator' WHERE profile_definition_id = 'chatgpt-codex'",
      );
      const before = db
        .prepare("SELECT * FROM tool_profile_starter_templates")
        .all();
      apply(db, sql("0007_chat_profile_starter_attestation.sql"));
      apply(db, sql("0008_codex_compatibility_approval_policy.sql"));
      expect(
        db.prepare("SELECT * FROM tool_profile_starter_templates").all(),
      ).toEqual(before);
    } finally {
      db.close();
    }
  });
});
