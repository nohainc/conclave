import { DatabaseSync } from "node:sqlite";
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { chatWorkflowAlignmentSql } from "./prepare-chat-workflow-migration.mjs";

function objects(db) {
  return db
    .prepare(
      "SELECT type,name,tbl_name,sql FROM sqlite_schema WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' ORDER BY type,name",
    )
    .all();
}
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

it("preserves historical checkout columns, index names, triggers and transitive dependencies", () => {
  const db = new DatabaseSync(":memory:");
  try {
    let baseline = readFileSync(
      new URL(
        "../apps/cloud/migrations-v8/0001_conclave_v8.sql",
        import.meta.url,
      ),
      "utf8",
    );
    baseline = baseline.replace(
      "  input_json TEXT NOT NULL DEFAULT '{}',\n  created_at TEXT NOT NULL,\n  updated_at TEXT NOT NULL,\n  snapshot_json",
      "  checkout_id TEXT REFERENCES thread_checkouts(id) ON DELETE RESTRICT,\n  input_json TEXT NOT NULL DEFAULT '{}',\n  created_at TEXT NOT NULL,\n  updated_at TEXT NOT NULL,\n  snapshot_json",
    );
    baseline = baseline
      .replaceAll("idx_work_requests_thread", "idx_v6_work_requests_thread")
      .replaceAll(
        "idx_workflow_tasks_request",
        "idx_v6_workflow_tasks_request",
      );
    db.exec(baseline);
    db.exec(`CREATE TABLE thread_checkouts(id TEXT PRIMARY KEY);
      CREATE TABLE historical_checkpoint(id TEXT PRIMARY KEY, request_id TEXT REFERENCES work_requests(id) ON DELETE RESTRICT, extra_json TEXT);
      CREATE TABLE checkpoint_link(id TEXT PRIMARY KEY, checkpoint_id TEXT REFERENCES historical_checkpoint(id) ON DELETE CASCADE);
      CREATE INDEX custom_checkpoint_index ON historical_checkpoint(request_id);
      CREATE TRIGGER preserve_checkout BEFORE UPDATE OF checkout_id ON work_requests WHEN OLD.checkout_id IS NOT NEW.checkout_id BEGIN SELECT RAISE(ABORT, 'immutable checkout'); END;
      INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('user','test@example.com','Test','now','now');
      INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('space','user','Space','now','now');
      INSERT INTO threads(id,space_id,name,status,lead_user_id,created_at,updated_at) VALUES('stream','space','Stream','active','user','now','now');
      INSERT INTO thread_checkouts VALUES('checkout');
      INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,checkout_id,created_at,updated_at,cancel_requested_at)
      VALUES('request','stream','user','stateless','direct',1,'{ "name": "Direct" }','cancelled','checkout','created','updated','cancelled-at');
      INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at)
      VALUES('task','request','implement','stateful_thread',900000,'implement:v1','failed','created','updated');
      INSERT INTO historical_checkpoint VALUES('checkpoint','request','{"preserve":true}');
      INSERT INTO checkpoint_link VALUES('link','checkpoint');`);
    db.exec("PRAGMA foreign_keys = ON");
    const originalObjects = objects(db);
    const tables = originalObjects
      .filter((o) => o.type === "table")
      .map((o) => o.name);
    const before = tables.map((t) => db.prepare(`SELECT * FROM "${t}"`).all());
    apply(db, chatWorkflowAlignmentSql(originalObjects));
    expect(tables.map((t) => db.prepare(`SELECT * FROM "${t}"`).all())).toEqual(
      before,
    );
    expect(objects(db).filter((o) => o.type !== "table")).toEqual(
      originalObjects.filter((o) => o.type !== "table"),
    );
    expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
    expect(() =>
      db.exec(
        "UPDATE work_requests SET checkout_id = NULL WHERE id = 'request'",
      ),
    ).toThrow("immutable checkout");
    db.exec(`INSERT INTO work_requests(id,thread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,status,created_at,updated_at) VALUES('chat','stream','user','stateless','chat',1,'{}','queued','now','now');
      INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at) VALUES('chat-task','chat','chat','stateless_read',900000,'chat:v1','queued','now','now');`);
  } finally {
    db.close();
  }
});

it("aborts before mutation when inspected schema changes", () => {
  const db = new DatabaseSync(":memory:");
  try {
    db.exec(
      readFileSync(
        new URL(
          "../apps/cloud/migrations-v8/0001_conclave_v8.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    const sql = chatWorkflowAlignmentSql(objects(db));
    db.exec("ALTER TABLE work_requests ADD COLUMN later_column TEXT");
    expect(() => apply(db, sql)).toThrow("CHECK");
    expect(
      db.prepare("PRAGMA table_info(work_requests)").all().at(-1).name,
    ).toBe("later_column");
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

it("prepares JSONC production config and never regenerates an applied migration", () => {
  const directory = mkdtempSync(join(tmpdir(), "conclave-migration-test-"));
  const db = new DatabaseSync(":memory:");
  try {
    db.exec(
      readFileSync(
        new URL(
          "../apps/cloud/migrations-v8/0001_conclave_v8.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    const schemaFile = join(directory, "schema.json");
    const configFile = new URL(
      "../infra/cloudflare/app.wrangler.jsonc",
      import.meta.url,
    ).pathname;
    const script = new URL(
      "./prepare-chat-workflow-migration.mjs",
      import.meta.url,
    ).pathname;
    writeFileSync(
      schemaFile,
      JSON.stringify([
        { success: true, results: objects(db) },
        { success: true, results: [] },
      ]),
    );
    execFileSync(process.execPath, [script, schemaFile, configFile, directory]);
    expect(
      JSON.parse(readFileSync(join(directory, "wrangler.json"), "utf8"))
        .d1_databases[0].migrations_dir,
    ).toBe(join(directory, "migrations"));
    expect(
      readFileSync(
        join(directory, "migrations/0006_chat_workflow_admission.sql"),
        "utf8",
      ),
    ).toContain("Schema-preserving instantiation");
    writeFileSync(
      schemaFile,
      JSON.stringify([
        { success: true, results: [] },
        {
          success: true,
          results: [{ name: "0006_chat_workflow_admission.sql" }],
        },
      ]),
    );
    execFileSync(process.execPath, [script, schemaFile, configFile, directory]);
    expect(
      readFileSync(
        join(directory, "migrations/0006_chat_workflow_admission.sql"),
        "utf8",
      ),
    ).toBe(
      readFileSync(
        new URL(
          "../apps/cloud/migrations-v8/0006_chat_workflow_admission.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
  } finally {
    db.close();
    rmSync(directory, { recursive: true, force: true });
  }
});
