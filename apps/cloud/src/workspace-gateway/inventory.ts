import type { WorkspaceGatewayEnv } from "./contracts.js";

/** Persists the Workspace-owned logical Worker snapshot and prunes omissions. */
export async function recordWorkspaceWorkerInventory(
  env: WorkspaceGatewayEnv,
  workspaceId: string | null,
  payload: unknown,
): Promise<void> {
  if (!workspaceId || !payload || typeof payload !== "object") return;
  const reports = (payload as Record<string, unknown>).workers;
  if (!Array.isArray(reports) || reports.length > 500) return;
  const owner = await env.CONCLAVE_DB.prepare(
    "SELECT owner_user_id FROM execution_workspaces WHERE id = ?1 AND status != 'revoked'",
  )
    .bind(workspaceId)
    .first<{ owner_user_id: string }>();
  if (!owner) return;
  const now = new Date().toISOString();
  const fullSnapshot =
    (payload as Record<string, unknown>).fullSnapshot === true;
  const reportedWorkerIds = new Set<string>();
  for (const raw of reports) {
    if (!raw || typeof raw !== "object") continue;
    const item = raw as Record<string, unknown>;
    const workerId = item.workerId;
    const workerTypeId = item.workerTypeId;
    const activationState = item.activationState;
    const readinessState = item.readinessState;
    const revision = item.revision;
    const concurrency = item.localConcurrencyLimit;
    if (
      typeof workerId !== "string" ||
      typeof workerTypeId !== "string" ||
      !["enabled", "disabled"].includes(String(activationState)) ||
      ![
        "not_probed",
        "ready",
        "setup_required",
        "sign_in_required",
        "worker_runtime_unavailable",
        "test_failed",
      ].includes(String(readinessState)) ||
      !Number.isSafeInteger(revision) ||
      (revision as number) < 1 ||
      !Number.isInteger(concurrency) ||
      (concurrency as number) < 1
    ) {
      continue;
    }
    const previous = await env.CONCLAVE_DB.prepare(
      "SELECT workspace_id, revision FROM workspace_worker_inventory WHERE worker_id = ?1",
    )
      .bind(workerId)
      .first<{ workspace_id: string; revision: number }>();
    // A Worker ID is permanently owned by the Workspace that first synced
    // it, and its local revision only moves forward.
    if (previous && previous.workspace_id !== workspaceId) {
      continue;
    }
    // Structurally valid entries count as reported even when their revision
    // is unchanged. Malformed entries cannot keep omitted Workers alive.
    reportedWorkerIds.add(workerId);
    if (previous && Number(previous.revision) >= (revision as number)) {
      if (Number(previous.revision) === revision) {
        await env.CONCLAVE_DB.prepare(
          `UPDATE workspace_worker_inventory SET last_seen_at = ?3
              WHERE worker_id = ?1 AND workspace_id = ?2 AND revision = ?4`,
        )
          .bind(workerId, workspaceId, now, revision)
          .run();
      }
      continue;
    }
    const arrayJson = (value: unknown, max: number): string =>
      JSON.stringify(
        Array.isArray(value)
          ? value
              .filter((entry): entry is string => typeof entry === "string")
              .map((entry) => entry.trim())
              .filter((entry) => /^[a-z][a-z0-9_:-]{0,127}$/.test(entry))
              .slice(0, max)
          : [],
      );
    const nullableText = (value: unknown, max: number): string | null =>
      typeof value === "string" && value.trim().length <= max
        ? value.trim() || null
        : null;
    const nullableSafeToken = (
      value: unknown,
      pattern: RegExp,
    ): string | null =>
      typeof value === "string" && pattern.test(value.trim())
        ? value.trim()
        : null;
    const readinessIssueCode =
      typeof item.readinessIssueCode === "string" &&
      /^[a-z][a-z0-9_]{0,127}$/.test(item.readinessIssueCode)
        ? item.readinessIssueCode
        : null;
    await env.CONCLAVE_DB.prepare(
      `INSERT INTO workspace_worker_inventory
          (worker_id, workspace_id, owner_user_id, worker_type_id,
           activation_state, readiness_state, readiness_issue_code,
           engine_version, profile_definition_id, profile_release_version,
           provider_tool_name, provider_tool_version,
           capabilities_json, local_concurrency_limit, revision,
           created_at, updated_at, last_seen_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
         ON CONFLICT(worker_id) DO UPDATE SET
           worker_type_id = excluded.worker_type_id,
           activation_state = excluded.activation_state,
           readiness_state = excluded.readiness_state,
           readiness_issue_code = excluded.readiness_issue_code,
           engine_version = excluded.engine_version,
           profile_definition_id = excluded.profile_definition_id,
           profile_release_version = excluded.profile_release_version,
           provider_tool_name = excluded.provider_tool_name,
           provider_tool_version = excluded.provider_tool_version,
           capabilities_json = excluded.capabilities_json,
           local_concurrency_limit = excluded.local_concurrency_limit,
           revision = excluded.revision,
           updated_at = excluded.updated_at,
           last_seen_at = excluded.last_seen_at
         WHERE workspace_worker_inventory.workspace_id = excluded.workspace_id
           AND workspace_worker_inventory.revision < excluded.revision`,
    )
      .bind(
        workerId,
        workspaceId,
        owner.owner_user_id,
        workerTypeId,
        activationState,
        readinessState,
        readinessIssueCode,
        nullableSafeToken(
          item.engineVersion,
          /^[A-Za-z0-9][A-Za-z0-9.+_-]{0,63}$/,
        ),
        typeof item.profileDefinitionId === "string" &&
          /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(item.profileDefinitionId) &&
          item.profileDefinitionId.length <= 96
          ? item.profileDefinitionId
          : null,
        Number.isSafeInteger(item.profileReleaseVersion) &&
          (item.profileReleaseVersion as number) > 0
          ? item.profileReleaseVersion
          : null,
        nullableSafeToken(
          item.providerToolName,
          /^[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}$/,
        ),
        nullableSafeToken(
          item.providerToolVersion,
          /^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$/,
        ),
        arrayJson(item.capabilities, 128),
        Math.min(1024, concurrency as number),
        revision,
        nullableText(item.createdAt, 40) ?? now,
        now,
        nullableText(item.lastSeenAt, 40) ?? now,
      )
      .run();
    await env.CONCLAVE_DB.prepare(
      `INSERT OR IGNORE INTO worker_scheduling (worker_id, state, updated_at)
         SELECT worker_id, 'disabled', ?2 FROM workspace_worker_inventory WHERE worker_id = ?1`,
    )
      .bind(workerId, now)
      .run();
  }
  // Full snapshots are authoritative. Removed local slots disappear from
  // inventory; scheduling and audit rows cascade with the inventory row.
  if (fullSnapshot) {
    const existing = await env.CONCLAVE_DB.prepare(
      `SELECT worker_id FROM workspace_worker_inventory
          WHERE workspace_id = ?1`,
    )
      .bind(workspaceId)
      .all<{ worker_id: string }>();
    for (const row of existing.results ?? []) {
      if (reportedWorkerIds.has(row.worker_id)) continue;
      await env.CONCLAVE_DB.prepare(
        `DELETE FROM workspace_worker_inventory
            WHERE worker_id = ?1 AND workspace_id = ?2`,
      )
        .bind(row.worker_id, workspaceId)
        .run();
    }
  }
}
