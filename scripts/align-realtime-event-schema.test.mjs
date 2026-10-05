import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { realtimeEventAlignmentSql } from "./align-realtime-event-schema.mjs";
it("adds the current runtime field without removing existing events", () => {
  const db = new DatabaseSync(":memory:");
  try {
    db.exec("CREATE TABLE realtime_events(event_id TEXT PRIMARY KEY, payload_json TEXT); INSERT INTO realtime_events VALUES('old','{}');");
    db.exec(realtimeEventAlignmentSql(readFileSync(new URL("../apps/cloud/migrations-v8/0001_conclave_v8.sql", import.meta.url), "utf8")));
    db.exec("INSERT INTO realtime_events(event_id,payload_json,workspace_runtime_id) VALUES('new','{}','runtime-1');");
    expect(db.prepare("SELECT count(*) AS n FROM realtime_events").get().n).toBe(2);
  } finally { db.close(); }
});
