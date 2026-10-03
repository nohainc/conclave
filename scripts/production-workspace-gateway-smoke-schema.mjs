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

export function productionSmokeSchemaIssues(tableNames, columnsByTable) {
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

  return issues;
}
