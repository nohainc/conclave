import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { realtimeStreamAlignmentSql } from "./align-realtime-stream-schema.mjs";

it("preserves legacy event identity, idempotency, payloads and retained sequence counters", () => {
  const db = new DatabaseSync(":memory:");
  try {
    db.exec(`CREATE TABLE realtime_event_cursors(workspace_id TEXT PRIMARY KEY, next_sequence INTEGER);
      CREATE TABLE realtime_events(event_id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, space_id TEXT,
      run_id TEXT, task_id TEXT, attempt_id TEXT, assignment_id TEXT, workspace_runtime_id TEXT,
      sequence INTEGER NOT NULL, event_type TEXT, payload_json TEXT, idempotency_key TEXT, occurred_at TEXT,
      UNIQUE(workspace_id, sequence), UNIQUE(workspace_id, idempotency_key));
      INSERT INTO realtime_event_cursors VALUES('same', 90);
      INSERT INTO realtime_events VALUES('old', 'same', 'p', NULL, NULL, NULL, NULL, 'runtime', 7, 'run.completed', '{"entityId":"r"}', 'idem', '2026-10-06T00:00:00.000Z');`);
    const sql = realtimeStreamAlignmentSql(
      readFileSync(
        new URL(
          "../apps/cloud/migrations-v8/0001_conclave_v8.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    db.exec("BEGIN");
    db.exec(sql);
    db.exec("COMMIT");
    expect(
      db
        .prepare(
          "SELECT stream_kind, stream_id, workspace_id, sequence, payload_json, workspace_runtime_id FROM realtime_events",
        )
        .get(),
    ).toMatchObject({
      stream_kind: "execution_workspace",
      stream_id: "same",
      workspace_id: "same",
      sequence: 7,
      payload_json: '{"entityId":"r"}',
      workspace_runtime_id: "runtime",
    });
    expect(
      db.prepare("SELECT next_sequence FROM realtime_event_cursors").get()
        .next_sequence,
    ).toBe(90);
    db.exec(`INSERT INTO realtime_events(event_id, stream_kind, stream_id, space_id, sequence, event_type, payload_json, idempotency_key, occurred_at)
      VALUES('new', 'space', 'same', 'same', 7, 'space.updated', '{"entityId":"same"}', 'idem', 'now');`);
    expect(
      db.prepare("SELECT COUNT(*) AS n FROM realtime_events").get().n,
    ).toBe(2);
    expect(() =>
      db.exec(`INSERT INTO realtime_events SELECT 'duplicate', stream_kind, stream_id, workspace_id, thread_id, space_id,
      run_id, task_id, attempt_id, assignment_id, workspace_runtime_id, sequence, event_type, payload_json, idempotency_key, occurred_at
      FROM realtime_events WHERE event_id = 'new'`),
    ).toThrow();
    expect(
      db
        .prepare(
          "SELECT COUNT(*) AS n FROM sqlite_master WHERE name LIKE '%alignment%'",
        )
        .get().n,
    ).toBe(0);
  } finally {
    db.close();
  }
});
