import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { workerAssignmentAlignmentSql } from "./align-worker-assignment-schema.mjs";

it("aligns the empty historical table and preserves inbound references and indexes", () => {
  const db = new DatabaseSync(":memory:");
  const baseline = readFileSync(new URL("../apps/cloud/migrations-v8/0001_conclave_v8.sql", import.meta.url), "utf8");
  try {
    db.exec(`PRAGMA foreign_keys=ON;
      CREATE TABLE worker_catalog(worker_type_id TEXT PRIMARY KEY);
      CREATE TABLE workers(id TEXT PRIMARY KEY);
      CREATE TABLE worker_assignments(id TEXT PRIMARY KEY, worker_id TEXT NOT NULL REFERENCES workers(id),
        account_id TEXT, checkout_id TEXT, execution_lease_id TEXT, status TEXT NOT NULL);
      CREATE TABLE results(assignment_id TEXT REFERENCES worker_assignments(id));
      CREATE INDEX assignments_status ON worker_assignments(status);
      INSERT INTO worker_catalog VALUES('chatgpt');`);
    expect(() => db.exec("INSERT INTO worker_assignments(id,worker_type_id,status) VALUES('a','chatgpt','created')")).toThrow();
    db.exec(workerAssignmentAlignmentSql(baseline));
    db.exec("INSERT INTO worker_assignments(id,worker_type_id,status) VALUES('a','chatgpt','created'); INSERT INTO results VALUES('a');");
    expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
    expect(() => db.exec("INSERT INTO worker_assignments(id,status) VALUES('b','created')")).toThrow();
    expect(() => db.exec("INSERT INTO worker_assignments(id,worker_type_id,status) VALUES('b','unknown','created')")).toThrow();
    expect(db.prepare("SELECT name FROM sqlite_master WHERE name='assignments_status'").get()).toBeTruthy();
  } finally { db.close(); }
});
