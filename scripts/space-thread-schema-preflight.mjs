import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export function assertSpaceThreadSchema(response) {
  if (
    !Array.isArray(response) ||
    response.some(
      (item) => item.success !== true || !Array.isArray(item.results),
    )
  ) {
    throw new Error("Database schema inspection failed; refusing migration.");
  }
  const tables = response
    .flatMap((item) => item.results)
    .filter((row) => row.type === "table");
  const names = new Set(tables.map((row) => row.name));
  const required = [
    "spaces",
    "threads",
    "space_memberships",
    "space_invitations",
    "workspace_space_grants",
  ];
  const missing = required.filter((name) => !names.has(name));
  const missingColumns = required.flatMap((name) => {
    const table = tables.find((row) => row.name === name);
    if (!table) return [];
    const column = name === "spaces" ? "owner_user_id" : "space_id";
    return new RegExp(`\\b${column}\\s+(?:TEXT|VARCHAR)\\b`, "i").test(
      table.sql ?? "",
    )
      ? []
      : [`${name}.${column}`];
  });
  const retired = tables.filter(
    (row) =>
      /^(?:projects|project_|workstreams|workstream_|workspace_project_grants)/.test(
        row.name,
      ) || /\b(?:project_id|workstream_id)\b/.test(row.sql ?? ""),
  );
  if (missing.length || missingColumns.length || retired.length) {
    throw new Error(
      `Space/Thread cutover required before v8 migrations. Missing: ${missing.join(", ") || "none"}; missing identity columns: ${missingColumns.join(", ") || "none"}; retired tables/columns: ${retired.map((row) => row.name).join(", ") || "none"}. Back up and convert the existing schema and persisted contracts; do not replay the edited fresh-start baseline or reset data.`,
    );
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    assertSpaceThreadSchema(JSON.parse(readFileSync(process.argv[2], "utf8")));
    console.log("Space/Thread schema preflight passed.");
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
