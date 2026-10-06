import { DatabaseSync } from "node:sqlite";
import { readFileSync, mkdirSync, cpSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";

const quote = (name) => `"${name.replaceAll('"', '""')}"`;
const literal = (value) => `'${value.replaceAll("'", "''")}'`;

// Instantiate the pending forward migration from the deployed schema. Preserve
// historical columns/objects without exposing compatibility runtime APIs.
export function chatWorkflowAlignmentSql(objects) {
  const tables = objects.filter((o) => o.type === "table");
  if (tables.some((o) => o.name.startsWith("__migration_0006_"))) {
    throw new Error("Unfinished Chat migration objects require inspection.");
  }
  const schema = new DatabaseSync(":memory:");
  try {
    for (const table of tables) schema.exec(table.sql);
    const byName = new Map(tables.map((t) => [t.name, t]));
    for (const name of ["work_requests", "workflow_tasks"]) {
      if (!byName.has(name)) throw new Error(`Missing required table: ${name}`);
    }
    const parents = new Map(
      tables.map((t) => [
        t.name,
        schema
          .prepare(`PRAGMA foreign_key_list(${quote(t.name)})`)
          .all()
          .map((fk) => fk.table),
      ]),
    );
    const affected = new Set(["work_requests", "workflow_tasks"]);
    let size;
    do {
      size = affected.size;
      for (const [child, references] of parents) {
        if (references.some((parent) => affected.has(parent)))
          affected.add(child);
      }
    } while (size !== affected.size);
    const order = [];
    const visiting = new Set();
    const visited = new Set();
    function visit(name) {
      if (visited.has(name)) return;
      if (visiting.has(name))
        throw new Error(
          `Cyclic foreign keys require manual alignment: ${name}`,
        );
      visiting.add(name);
      for (const parent of parents.get(name))
        if (affected.has(parent)) visit(parent);
      visiting.delete(name);
      visited.add(name);
      order.push(name);
    }
    for (const name of affected) visit(name);
    for (const name of order) {
      if (/\bAUTOINCREMENT\b/i.test(byName.get(name).sql))
        throw new Error(
          `AUTOINCREMENT requires explicit sequence preservation: ${name}`,
        );
    }
    const backup = (name) => quote(`__migration_0006_${name}`);
    const guards = objects.filter((o) => affected.has(o.tbl_name));
    const out = [
      "-- Schema-preserving instantiation of 0006; apply atomically through D1 migrations.",
      "PRAGMA defer_foreign_keys = ON;",
      "CREATE TABLE __migration_0006_assertion (valid INTEGER NOT NULL CHECK (valid = 1));",
      // Compare metadata with the read-only preparation snapshot before mutation.
      `INSERT INTO __migration_0006_assertion SELECT CASE WHEN (SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND sql IS NOT NULL AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%' AND name <> '__migration_0006_assertion') = ${tables.length} THEN 1 ELSE 0 END;`,
      ...objects
        .filter((o) => o.type === "table" || affected.has(o.tbl_name))
        .map(
          (o) =>
            `INSERT INTO __migration_0006_assertion SELECT CASE WHEN EXISTS (SELECT 1 FROM sqlite_schema WHERE type = ${literal(o.type)} AND name = ${literal(o.name)} AND sql = ${literal(o.sql)}) THEN 1 ELSE 0 END;`,
        ),
      `INSERT INTO __migration_0006_assertion SELECT CASE WHEN (SELECT COUNT(*) FROM sqlite_schema WHERE tbl_name IN (${order.map(literal).join(",")}) AND sql IS NOT NULL) = ${guards.length} THEN 1 ELSE 0 END;`,
      ...order.map(
        (name) =>
          `CREATE TABLE ${backup(name)} AS SELECT * FROM ${quote(name)};`,
      ),
      // Drop descendants first: no CASCADE/SET NULL/RESTRICT target remains.
      ...[...order].reverse().map((name) => `DROP TABLE ${quote(name)};`),
    ];
    const inserts = [];
    for (const name of order) {
      let ddl = byName.get(name).sql;
      const column =
        name === "work_requests"
          ? "workflow_id"
          : name === "workflow_tasks"
            ? "step_kind"
            : null;
      if (column) {
        const pattern = new RegExp(`\\b${column}\\s+IN\\s*\\(([^)]*)\\)`, "i");
        const match = ddl.match(pattern);
        if (!match || !/'(?:direct|research)'/.test(match[1]))
          throw new Error(`Unknown ${column} constraint`);
        if (!/'chat'/.test(match[1]))
          ddl = ddl.replace(pattern, `${column} IN ('chat', ${match[1]})`);
      }
      out.push(`${ddl};`);
      const columns = schema
        .prepare(`PRAGMA table_xinfo(${quote(name)})`)
        .all()
        .filter((c) => c.hidden === 0)
        .map((c) => quote(c.name))
        .join(",");
      inserts.push(
        `INSERT INTO ${quote(name)} (${columns}) SELECT ${columns} FROM ${backup(name)};`,
      );
    }
    for (const object of guards.filter((o) => o.type === "index"))
      out.push(`${object.sql};`);
    out.push(...inserts);
    // Restore triggers only after all rows are restored: no audit or immutable
    // snapshot trigger sees synthetic migration INSERT/UPDATE events.
    for (const object of guards.filter((o) => o.type === "trigger"))
      out.push(`${object.sql};`);
    for (const name of order) {
      out.push(
        `INSERT INTO __migration_0006_assertion SELECT CASE WHEN (SELECT COUNT(*) FROM ${quote(name)}) = (SELECT COUNT(*) FROM ${backup(name)}) AND NOT EXISTS (SELECT * FROM ${quote(name)} EXCEPT SELECT * FROM ${backup(name)}) AND NOT EXISTS (SELECT * FROM ${backup(name)} EXCEPT SELECT * FROM ${quote(name)}) THEN 1 ELSE 0 END;`,
      );
    }
    out.push(
      ...order.map((name) => `DROP TABLE ${backup(name)};`),
      "DROP TABLE __migration_0006_assertion;",
    );
    // Leave deferred enforcement enabled until commit; D1 validates restored FKs.
    return `${out.join("\n")}\n`;
  } finally {
    schema.close();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [schemaFile, configFile, directory] = process.argv.slice(2);
  const root = fileURLToPath(new URL("../", import.meta.url));
  const results = JSON.parse(readFileSync(schemaFile, "utf8"));
  if (!Array.isArray(results) || results.some((r) => !r.success))
    throw new Error("Production schema inspection failed.");
  const require = createRequire(import.meta.url);
  const wranglerRequire = createRequire(
    require.resolve("wrangler/package.json"),
  );
  const errors = [];
  const config = wranglerRequire("jsonc-parser").parse(
    readFileSync(configFile, "utf8"),
    errors,
    { allowTrailingComma: true },
  );
  if (errors.length || !Array.isArray(config.d1_databases))
    throw new Error("Invalid D1 configuration.");
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  cpSync(
    join(root, "apps/cloud/migrations-v8"),
    join(directory, "migrations"),
    { recursive: true },
  );
  if (
    !results[1]?.results.some(
      (r) => r.name === "0006_chat_workflow_admission.sql",
    )
  ) {
    writeFileSync(
      join(directory, "migrations/0006_chat_workflow_admission.sql"),
      chatWorkflowAlignmentSql(results[0].results),
      { mode: 0o600 },
    );
  }
  writeFileSync(
    join(directory, "wrangler.json"),
    JSON.stringify(
      {
        name: config.name,
        account_id: config.account_id,
        compatibility_date: config.compatibility_date,
        d1_databases: config.d1_databases.map((binding) => ({
          ...binding,
          migrations_dir: resolve(directory, "migrations"),
        })),
      },
      null,
      2,
    ),
    { mode: 0o600 },
  );
  console.log(
    "Prepared schema-preserving pending migrations; production rows have not been modified.",
  );
}
