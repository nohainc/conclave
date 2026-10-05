import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

// One-time repair for an empty, obsolete hosted table; never a baseline migration.
export function workerAssignmentAlignmentSql(baseline) {
  const table = baseline.match(
    /CREATE TABLE worker_assignments \([\s\S]*?\n\);/,
  );
  const column = table?.[0]
    .match(/^  worker_type_id .*,$/m)?.[0]
    .trim()
    .slice(0, -1);
  if (!column || /\bworker_id TEXT/.test(table[0])) {
    throw new Error(
      "Expected the current provider-independent v8 assignment schema.",
    );
  }
  return (
    `ALTER TABLE worker_assignments ADD COLUMN ${column};\n` +
    ["worker_id", "account_id", "checkout_id", "execution_lease_id"]
      .map((name) => `ALTER TABLE worker_assignments DROP COLUMN ${name};\n`)
      .join("")
  );
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const root = new URL("../", import.meta.url);
  mkdirSync(new URL(".development/", root), { recursive: true });
  writeFileSync(
    new URL(".development/align-worker-assignment-schema.sql", root),
    workerAssignmentAlignmentSql(
      readFileSync(
        new URL("apps/cloud/migrations-v8/0001_conclave_v8.sql", root),
        "utf8",
      ),
    ),
  );
  console.log(
    "Prepared assignment alignment. Apply only after schema backup, empty-table and dependency checks.",
  );
}
