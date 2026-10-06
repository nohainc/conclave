import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

/** One-time deployed-schema alignment, not a fresh-start migration chain.
 * Requires the existing workspace_runtime_id field alignment first.
 */
export function realtimeStreamAlignmentSql(baseline) {
  const tables = ["realtime_event_cursors", "realtime_events"];
  const definitions = tables.map((name) => {
    const ddl = baseline.match(
      new RegExp(`CREATE TABLE ${name} \\([\\s\\S]*?\\n\\);`),
    )?.[0];
    if (!ddl) throw new Error(`Missing baseline table ${name}`);
    return ddl.replace(
      `CREATE TABLE ${name}`,
      `CREATE TABLE ${name}_stream_alignment`,
    );
  });
  const indexes = [
    ...baseline.matchAll(
      /CREATE (?:UNIQUE )?INDEX [^;]+\s+ON realtime_event(?:s|_cursors)\([^;]+;/g,
    ),
  ].map((match) => match[0]);
  return `-- Apply once, before the stream-aware publisher is deployed.\n${definitions.join("\n")}
INSERT INTO realtime_event_cursors_stream_alignment(stream_kind, stream_id, workspace_id, next_sequence)
  SELECT 'execution_workspace', workspace_id, workspace_id, next_sequence FROM realtime_event_cursors;
INSERT INTO realtime_events_stream_alignment
 (event_id, stream_kind, stream_id, workspace_id, project_id, run_id, task_id, attempt_id,
  assignment_id, workspace_runtime_id, sequence, event_type, payload_json, idempotency_key, occurred_at)
 SELECT event_id, 'execution_workspace', workspace_id, workspace_id, project_id, run_id, task_id, attempt_id,
  assignment_id, workspace_runtime_id, sequence, event_type, payload_json, idempotency_key, occurred_at FROM realtime_events;
DROP TABLE realtime_events;
DROP TABLE realtime_event_cursors;
ALTER TABLE realtime_events_stream_alignment RENAME TO realtime_events;
ALTER TABLE realtime_event_cursors_stream_alignment RENAME TO realtime_event_cursors;
${indexes.join("\n")}\n`;
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  mkdirSync(new URL("../.development/", import.meta.url), { recursive: true });
  writeFileSync(
    new URL(
      "../.development/align-realtime-stream-schema.sql",
      import.meta.url,
    ),
    realtimeStreamAlignmentSql(
      readFileSync(
        new URL(
          "../apps/cloud/migrations-v8/0001_conclave_v8.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    ),
  );
}
