import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));

export const requiredProductionSmokeColumns = Object.freeze({
  users: [
    "id",
    "email",
    "display_name",
    "status",
    "created_at",
    "updated_at",
    "avatar_url",
    "email_verified",
  ],
  execution_workspaces: [
    "id",
    "owner_user_id",
    "name",
    "status",
    "created_at",
    "updated_at",
  ],
  workspace_runtime_identities: [
    "id",
    "workspace_id",
    "credential_token_hash",
    "installation_id",
    "created_at",
    "revoked_at",
  ],
  workspace_runtime_facts: [
    "workspace_id",
    "platform",
    "architecture",
    "hostname",
    "app_version",
    "runtime_capabilities_json",
    "updated_at",
  ],
  workspace_sessions: [
    "id",
    "workspace_id",
    "runtime_identity_id",
    "client_version",
    "protocol_version",
    "ip_address",
    "connected_at",
    "last_heartbeat_at",
    "disconnected_at",
  ],
  desktop_auth_intents: [
    "id",
    "poll_token_hash",
    "client_name",
    "audience",
    "created_at",
    "expires_at",
    "approved_at",
    "approved_user_id",
    "claimed_at",
    "claimed_session_id",
    "denied_at",
  ],
  desktop_human_sessions: [
    "id",
    "user_id",
    "token_hash",
    "audience",
    "created_at",
    "last_used_at",
    "expires_at",
    "revoked_at",
  ],
});

const tableDefinitionSources = Object.freeze({
  execution_workspaces: [
    "apps/cloud/migrations-v8/0001_conclave_v8.sql",
    "execution_workspaces",
  ],
  workspace_runtime_identities: [
    "apps/cloud/migrations-v8/0001_conclave_v8.sql",
    "workspace_runtime_identities",
  ],
  desktop_auth_intents: [
    "apps/cloud/migrations-v8/0002_desktop_auth_multi_audience.sql",
    "desktop_auth_intents__multi_audience",
  ],
  desktop_human_sessions: [
    "apps/cloud/migrations-v8/0002_desktop_auth_multi_audience.sql",
    "desktop_human_sessions__multi_audience",
  ],
});

function extractCreateTableDefinition(sql, tableName) {
  const escapedTableName = tableName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = sql.match(
    new RegExp(
      `CREATE TABLE\\s+${escapedTableName}\\s*\\([\\s\\S]*?\\n\\);`,
      "i",
    ),
  );
  if (!match) {
    throw new Error(
      `Missing canonical CREATE TABLE definition for ${tableName}`,
    );
  }
  return match[0].replace(/;\s*$/, "");
}

export const requiredProductionSmokeTableDefinitions = Object.freeze(
  Object.fromEntries(
    Object.entries(tableDefinitionSources).map(
      ([tableName, [migrationPath, sourceTableName]]) => {
        const migrationSql = readFileSync(
          join(repositoryRoot, migrationPath),
          "utf8",
        );
        const sourceDefinition = extractCreateTableDefinition(
          migrationSql,
          sourceTableName,
        );
        const definition = sourceDefinition.replace(
          new RegExp(`^(CREATE TABLE\\s+)${sourceTableName}\\b`, "i"),
          `$1${tableName}`,
        );
        return [tableName, definition];
      },
    ),
  ),
);

function normalizeTableDefinition(definition) {
  return definition
    .replaceAll('"', "")
    .replaceAll("`", "")
    .replaceAll("[", "")
    .replaceAll("]", "")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/;$/, "")
    .toLowerCase();
}

function hasBothDesktopAuthAudiences(definition) {
  const normalized = normalizeTableDefinition(definition);
  return /check\s*\(\s*audience\s+in\s*\(\s*'conclave\.desktop\.management'\s*,\s*'conclave\.profile-lab\.management'\s*\)\s*\)/.test(
    normalized,
  );
}

export function productionSmokeSchemaIssues(
  tableNames,
  columnsByTable,
  definitionsByTable = {},
) {
  const tables = new Set(tableNames);
  const issues = [];

  for (const [table, requiredColumns] of Object.entries(
    requiredProductionSmokeColumns,
  )) {
    if (!tables.has(table)) {
      issues.push(`missing table ${table}`);
      continue;
    }

    const actualColumns = new Set(columnsByTable[table] ?? []);
    const missing = requiredColumns.filter(
      (column) => !actualColumns.has(column),
    );
    const unexpected = [...actualColumns].filter(
      (column) => !requiredColumns.includes(column),
    );
    if (missing.length > 0) {
      issues.push(`${table} is missing columns: ${missing.join(", ")}`);
    }
    if (unexpected.length > 0) {
      issues.push(`${table} has unexpected columns: ${unexpected.join(", ")}`);
    }
  }

  for (const [table, expectedDefinition] of Object.entries(
    requiredProductionSmokeTableDefinitions,
  )) {
    const actualDefinition = definitionsByTable[table];
    if (typeof actualDefinition !== "string") {
      issues.push(`missing CREATE TABLE definition for ${table}`);
      continue;
    }

    if (
      (table === "desktop_auth_intents" ||
        table === "desktop_human_sessions") &&
      !hasBothDesktopAuthAudiences(actualDefinition)
    ) {
      issues.push(
        `Production D1 ${table} has legacy single-audience constraint. Apply pending migration before deployment.`,
      );
      continue;
    }

    if (
      normalizeTableDefinition(actualDefinition) !==
      normalizeTableDefinition(expectedDefinition)
    ) {
      issues.push(
        `Production D1 ${table} table definition differs from the v8 contract. Apply a forward migration before deployment.`,
      );
    }
  }

  return issues;
}
