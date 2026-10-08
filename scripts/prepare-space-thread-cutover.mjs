import { DatabaseSync } from "node:sqlite";
import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { assertSpaceThreadSchema } from "./space-thread-schema-preflight.mjs";
const quote = (name) => `"${name.replaceAll('"', '""')}"`;
const literal = (value) => `'${value.replaceAll("'", "''")}'`;
const rename = (text) =>
  text.replaceAll("'stateful_workstream'", "'stateful_thread'").replace(
    /\bprojects\b|\bproject(?=_)|\bworkspace_project(?=_)|\bworkstreams\b|\bworkstream(?=_)|\b(project|workstream)\b/g,
    (word) =>
      ({
        projects: "spaces",
        project: "space",
        workspace_project: "workspace_space",
        workstreams: "threads",
        workstream: "thread",
      })[word],
  );
const jsonKeys = {
  projectId: "spaceId",
  projectName: "spaceName",
  workstreamId: "threadId",
  workstreamTitle: "threadTitle",
  workstreamInstructions: "threadInstructions",
  workspaceProjectGrantId: "workspaceSpaceGrantId",
};
const metadata = new Set([
  "realtime_events",
  "work_requests",
  "worker_assignments",
  "workstream_work_configs",
  "project_audit_log",
  "workstream_audit_log",
  "runs",
]);

// One-off operational conversion, instantiated from the inspected database.
// Historical extra columns/tables remain; fresh-start baseline files are untouched.
export function spaceThreadCutoverSql(objects) {
  const inspectedTables = objects.filter(
    (o) => o.type === "table" && o.name !== "d1_migrations",
  );
  let tables = inspectedTables;
  const preRename =
    tables.some((t) => t.name === "projects") &&
    !tables.some((t) => /^(spaces|threads)/.test(t.name));
  const executionModeRepair =
    [
      "spaces",
      "threads",
      "space_memberships",
      "space_invitations",
      "workspace_space_grants",
    ].every((name) => tables.some((t) => t.name === name)) &&
    !tables.some((t) =>
      /^(projects|project_|workstreams|workstream_|workspace_project_grants)/.test(
        t.name,
      ),
    ) &&
    tables.some(
      (t) => t.name === "workflow_tasks" && /'stateful_workstream'/.test(t.sql),
    );
  if (
    (!preRename && !executionModeRepair) ||
    tables.some((t) => t.name.startsWith("__cutover_"))
  )
    throw new Error(
      "Expected an unmixed pre-rename schema or inspected workflow execution-mode drift.",
    );
  const db = new DatabaseSync(":memory:");
  try {
    for (const table of inspectedTables) db.exec(table.sql);
    if (executionModeRepair) {
      const affected = new Set(["workflow_tasks"]);
      let expanded = true;
      while (expanded) {
        expanded = false;
        for (const table of inspectedTables) {
          if (
            !affected.has(table.name) &&
            db
              .prepare(`PRAGMA foreign_key_list(${quote(table.name)})`)
              .all()
              .some((f) => affected.has(f.table))
          ) {
            affected.add(table.name);
            expanded = true;
          }
        }
      }
      tables = inspectedTables.filter((table) => affected.has(table.name));
    }
    const affectedNames = new Set(tables.map((table) => table.name));
    const parents = new Map(
      tables.map((t) => [
        t.name,
        db
          .prepare(`PRAGMA foreign_key_list(${quote(t.name)})`)
          .all()
          .map((f) => f.table),
      ]),
    );
    const order = [],
      seen = new Set(),
      active = new Set();
    function visit(name) {
      if (seen.has(name)) return;
      if (active.has(name))
        throw new Error(
          `Cyclic foreign keys require a reviewed conversion: ${name}`,
        );
      if (!parents.has(name)) throw new Error(`Missing parent ${name}`);
      active.add(name);
      for (const parent of parents.get(name))
        if (affectedNames.has(parent)) visit(parent);
      active.delete(name);
      seen.add(name);
      order.push(name);
    }
    for (const table of tables) {
      if (/AUTOINCREMENT/i.test(table.sql))
        throw new Error(
          "Explicit sequence preservation is required for AUTOINCREMENT.",
        );
      visit(table.name);
    }
    const backup = (name) => quote(`__cutover_${name}`);
    const assertion = (sql) =>
      `INSERT INTO __cutover_assert SELECT CASE WHEN (${sql}) THEN 1 ELSE 0 END;`;
    const out = [
      "PRAGMA defer_foreign_keys = ON;",
      "CREATE TABLE __cutover_assert (valid INTEGER NOT NULL CHECK(valid = 1));",
    ];
    out.push(
      assertion(
        `(SELECT COUNT(*) FROM sqlite_schema WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name <> '__cutover_assert')=${objects.length}`,
      ),
    );
    for (const table of inspectedTables) {
      const columns = db
        .prepare(`PRAGMA table_info(${quote(table.name)})`)
        .all();
      if (!columns.some((c) => c.name === "status")) continue;
      if (["work_requests", "worker_assignments"].includes(table.name)) {
        out.push(
          assertion(
            `NOT EXISTS (SELECT 1 FROM ${quote(table.name)} WHERE status NOT IN ('completed','failed','cancelled','expired'))`,
          ),
        );
      }
      if (table.name.endsWith("_leases"))
        out.push(
          assertion(
            `NOT EXISTS (SELECT 1 FROM ${quote(table.name)} WHERE status='active')`,
          ),
        );
    }
    for (const obj of objects)
      out.push(
        assertion(
          `EXISTS (SELECT 1 FROM sqlite_schema WHERE type=${literal(obj.type)} AND name=${literal(obj.name)} AND sql=${literal(obj.sql)})`,
        ),
      );
    for (const table of tables)
      out.push(
        `CREATE TABLE ${backup(table.name)} AS SELECT * FROM ${quote(table.name)};`,
      );
    for (const view of objects.filter((o) => o.type === "view"))
      out.push(`DROP VIEW ${quote(view.name)};`);
    // Descendants first prevents cascading changes to copied parent rows.
    for (const name of [...order].reverse())
      out.push(`DROP TABLE ${quote(name)};`);
    const transformed = inspectedTables.filter(
      (table) => !affectedNames.has(table.name),
    );
    for (const name of order) {
      const table = tables.find((t) => t.name === name),
        target = rename(name);
      const ddl = rename(table.sql);
      out.push(ddl + ";");
      transformed.push({ type: "table", name: target, sql: ddl });
      const columns = db
        .prepare(`PRAGMA table_info(${quote(name)})`)
        .all()
        .map((c) => c.name);
      const expressions = columns.map((column) => {
        const value = quote(column);
        if (name === "workflow_tasks" && column === "execution_mode")
          return `CASE ${value} WHEN 'stateful_workstream' THEN 'stateful_thread' ELSE ${value} END`;
        if (column === "stream_kind")
          return `CASE ${value} WHEN 'project' THEN 'space' WHEN 'workstream' THEN 'thread' ELSE ${value} END`;
        if (metadata.has(name) && column.endsWith("_json")) {
          let expression = `json(${value})`;
          for (const [oldKey, newKey] of Object.entries(jsonKeys)) {
            // Collisions are ambiguous, so stop rather than silently overwrite.
            out.push(
              assertion(
                `NOT EXISTS (SELECT 1 FROM ${backup(name)} WHERE ${value} IS NOT NULL AND instr(json(${value}), ${literal('"' + oldKey + '":')}) > 0 AND instr(json(${value}), ${literal('"' + newKey + '":')}) > 0)`,
              ),
            );
            expression = `replace(${expression},${literal('"' + oldKey + '":')},${literal('"' + newKey + '":')})`;
          }
          for (const [oldValue, newValue] of [
            ["project", "space"],
            ["workstream", "thread"],
          ])
            expression = `replace(${expression},${literal('"kind":"' + oldValue + '"')},${literal('"kind":"' + newValue + '"')})`;
          return `CASE WHEN ${value} IS NULL THEN NULL ELSE ${expression} END`;
        }
        if (column === "event_type")
          return `replace(replace(replace(${value},'project.','space.'),'workstream.','thread.'),'project_workspace_grant.','space_workspace_grant.')`;
        return value;
      });
      const select = `SELECT ${expressions.join(",")} FROM ${backup(name)}`;
      out.push(
        `INSERT INTO ${quote(target)} (${columns.map((c) => quote(rename(c))).join(",")}) ${select};`,
      );
      out.push(
        assertion(
          `(SELECT COUNT(*) FROM ${quote(target)})=(SELECT COUNT(*) FROM ${backup(name)}) AND NOT EXISTS (SELECT * FROM ${quote(target)} EXCEPT ${select}) AND NOT EXISTS (${select} EXCEPT SELECT * FROM ${quote(target)})`,
        ),
      );
    }
    for (const object of objects.filter(
      (o) =>
        o.type === "view" ||
        (o.type !== "table" && affectedNames.has(o.tbl_name)),
    ))
      out.push(rename(object.sql) + ";");
    out.push(assertion("NOT EXISTS (SELECT 1 FROM pragma_foreign_key_check)"));
    for (const name of order) out.push(`DROP TABLE ${backup(name)};`);
    out.push("DROP TABLE __cutover_assert;");
    assertSpaceThreadSchema([{ success: true, results: transformed }]);
    return out.join("\n") + "\n";
  } finally {
    db.close();
  }
}

export function spaceThreadCutoverMigrationName(objects) {
  return objects.some(
    (row) =>
      row.type === "table" &&
      row.name === "workflow_tasks" &&
      /'stateful_workstream'/.test(row.sql ?? ""),
  )
    ? "0021_workflow_execution_mode_alignment.sql"
    : "0017_space_thread_cutover.sql";
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [schemaFile, configFile, directory] = process.argv.slice(2);
  const snapshot = JSON.parse(readFileSync(schemaFile, "utf8"));
  if (!Array.isArray(snapshot) || snapshot.some((r) => !r.success))
    throw new Error("Schema inspection failed.");
  const require = createRequire(import.meta.url);
  const configRequire = createRequire(require.resolve("wrangler/package.json"));
  const errors = [];
  const config = configRequire("jsonc-parser").parse(
    readFileSync(configFile, "utf8"),
    errors,
    { allowTrailingComma: true },
  );
  if (errors.length || !Array.isArray(config.d1_databases))
    throw new Error("Invalid D1 config.");
  mkdirSync(join(directory, "migrations"), { recursive: true, mode: 0o700 });
  writeFileSync(
    join(
      directory,
      "migrations",
      spaceThreadCutoverMigrationName(snapshot[0].results),
    ),
    spaceThreadCutoverSql(snapshot[0].results),
    { mode: 0o600 },
  );
  writeFileSync(
    join(directory, "wrangler.json"),
    JSON.stringify(
      {
        name: config.name,
        account_id: config.account_id,
        compatibility_date: config.compatibility_date,
        d1_databases: config.d1_databases.map((b) => ({
          ...b,
          migrations_dir: resolve(directory, "migrations"),
        })),
      },
      null,
      2,
    ),
    { mode: 0o600 },
  );
  console.log(
    "Prepared isolated data-preserving cutover migration. No remote data changed.",
  );
}
