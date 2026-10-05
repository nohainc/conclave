import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
export function realtimeEventAlignmentSql(baseline) {
  const table = baseline.match(/CREATE TABLE realtime_events \([\s\S]*?\n\);/);
  const column = table?.[0]
    .match(/^  workspace_runtime_id .*,$/m)?.[0]
    .trim()
    .slice(0, -1);
  if (!column) throw new Error("Expected current v8 realtime event schema");
  return `ALTER TABLE realtime_events ADD COLUMN ${column};\n`;
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const root = new URL("../", import.meta.url);
  mkdirSync(new URL(".development/", root), { recursive: true });
  writeFileSync(
    new URL(".development/align-realtime-event-schema.sql", root),
    realtimeEventAlignmentSql(
      readFileSync(
        new URL("apps/cloud/migrations-v8/0001_conclave_v8.sql", root),
        "utf8",
      ),
    ),
  );
}
