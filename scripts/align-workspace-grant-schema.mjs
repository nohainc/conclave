import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export function workspaceGrantScopeAlignmentSql(baseline) {
  const table = baseline.match(
    /CREATE TABLE workspace_project_grants \([\s\S]*?\n\);/,
  );
  if (!table || /\bscope\s+TEXT/i.test(table[0])) {
    throw new Error(
      "Current v8 baseline must define project grants without legacy scope.",
    );
  }
  return "ALTER TABLE workspace_project_grants DROP COLUMN scope;\n";
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const root = new URL("../", import.meta.url);
  mkdirSync(new URL(".development/", root), { recursive: true });
  writeFileSync(
    new URL(".development/align-workspace-grant-schema.sql", root),
    workspaceGrantScopeAlignmentSql(
      readFileSync(
        new URL("apps/cloud/migrations-v8/0001_conclave_v8.sql", root),
        "utf8",
      ),
    ),
  );
  console.log(
    "Prepared scope-column alignment. Back up the table and verify scope exists and has no external dependencies before applying once.",
  );
}
