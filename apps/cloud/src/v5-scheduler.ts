import { resolveEffectivePermissions } from "@conclave/core";

export interface ProjectExecutionSelectionRequest {
  readonly projectId: string;
  readonly requesterUserId: string;
  readonly role: string;
  readonly capabilities: readonly string[];
  readonly accountId?: string;
  readonly configuredWorkerId?: string;
  readonly workspaceId?: string;
  readonly workerId?: string;
  readonly excludeIndependenceKeys?: readonly string[];
  readonly model?: string;
  readonly executionClass?: "stateless_read" | "stateful_workstream";
  readonly workstreamId?: string;
  readonly workRequestId?: string;
  readonly expectedRevision?: string;
}

export interface V5ExecutionTarget {
  readonly projectId: string;
  readonly workspaceId: string;
  readonly workspaceRuntimeIdentityId: string;
  readonly workspaceProjectGrantId: string;
  /** Configured Worker identity selected for this assignment. */
  readonly configuredWorkerId: string;
  /** Worker Type/catalog identity used to resolve the package. */
  readonly workerTypeId: string;
  /** Compatibility alias for configuredWorkerId during the migration. */
  readonly workerId: string;
  readonly workerVersion: string;
  /** Internal legacy accounting identity, when one exists. */
  readonly accountId?: string;
  readonly credentialId?: string;
  readonly credentialOwnerUserId?: string;
  readonly model: string | null;
  readonly effectivePermissions: readonly string[];
  readonly permissionSnapshot: Record<string, unknown>;
  readonly selectionExplanation: Record<string, unknown>;
  readonly executionClass: "stateless_read" | "stateful_workstream";
  readonly workstreamId?: string;
  readonly workRequestId?: string;
  readonly checkoutId?: string;
  readonly leaseId?: string;
  readonly fencingToken?: number;
  readonly expectedRevision?: string;
}

type Row = Record<string, unknown>;

function strings(value: unknown): string[] {
  if (typeof value !== "string") return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed)
      ? parsed.filter((item): item is string => typeof item === "string")
      : [];
  } catch {
    return [];
  }
}

function object(value: unknown): Record<string, unknown> {
  if (typeof value !== "string") return {};
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : {};
  } catch {
    return {};
  }
}

function number(value: unknown, fallback = 0): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function projectPermissions(role: string): string[] {
  if (role === "owner")
    return [
      "repository:read",
      "repository:write",
      "shell:execute",
      "network:use",
    ];
  if (role === "collaborator") return ["repository:read", "repository:write"];
  return ["repository:read"];
}

function allowedByJson(row: Row, key: string, value: string): boolean {
  const allowed = strings(row[key]);
  return allowed.length === 0 || allowed.includes(value);
}

/**
 * Resolves a Project execution target without consulting v4 Workspace or Host
 * tenancy. The returned explanation is persisted with the assignment.
 */
export async function selectProjectExecutionTarget(
  db: D1Database,
  request: ProjectExecutionSelectionRequest,
  now = new Date(),
): Promise<V5ExecutionTarget | null> {
  const membership = await db
    .prepare(
      `SELECT role FROM project_memberships WHERE project_id = ?1 AND user_id = ?2`,
    )
    .bind(request.projectId, request.requesterUserId)
    .first<{ role: string }>();
  if (!membership || membership.role === "viewer") return null;

  if (request.workstreamId) {
    const workstream = await db
      .prepare(
        `SELECT ws.project_id, ws.lead_user_id, ws.access_policy_json
           FROM workstreams ws
          WHERE ws.id = ?1`,
      )
      .bind(request.workstreamId)
      .first<Record<string, unknown>>();
    // Older test doubles and compatibility callers may not expose the
    // Workstream read model yet; production rows always include project_id.
    if (typeof workstream?.project_id === "string") {
      if (workstream.project_id !== request.projectId) return null;
      if (membership.role !== "owner") {
        const policy = object(workstream.access_policy_json);
        const allowedUsers = Array.isArray(policy.allowedUserIds)
          ? policy.allowedUserIds.filter(
              (value): value is string => typeof value === "string",
            )
          : [];
        const allowedRoles = Array.isArray(policy.allowedProjectRoles)
          ? policy.allowedProjectRoles.filter(
              (value): value is string => typeof value === "string",
            )
          : [];
        const allowedPermissions = Array.isArray(policy.allowedPermissions)
          ? policy.allowedPermissions.filter(
              (value): value is string => typeof value === "string",
            )
          : [];
        if (
          (allowedUsers.length > 0 &&
            !allowedUsers.includes(request.requesterUserId)) ||
          (allowedRoles.length > 0 &&
            !allowedRoles.includes(membership.role)) ||
          !allowedPermissions.includes("execute")
        ) {
          return null;
        }
      }
    }
  }

  const executionClass = request.executionClass ?? "stateless_read";
  let statefulLease: {
    workstreamId: string;
    workRequestId: string;
    workspaceId: string;
    checkoutId: string;
    leaseId: string;
    fencingToken: number;
    expectedRevision: string;
  } | null = null;
  if (executionClass === "stateful_workstream") {
    if (!request.workstreamId || !request.workRequestId) return null;
    statefulLease = await db
      .prepare(
        `SELECT wr.workstream_id AS workstreamId, wr.id AS workRequestId,
              wr.primary_workspace_id AS workspaceId, wr.checkout_id AS checkoutId,
              l.id AS leaseId, l.fencing_token AS fencingToken,
              c.revision AS expectedRevision, p.primary_workspace_id AS primaryWorkspaceId
       FROM work_requests wr
       JOIN workstream_execution_leases l ON l.work_request_id = wr.id
        AND l.workstream_id = wr.workstream_id AND l.status = 'active'
       JOIN workstream_checkouts c ON c.id = wr.checkout_id
        AND c.workstream_id = wr.workstream_id AND c.status = 'ready'
       JOIN workstream_execution_policies p ON p.workstream_id = wr.workstream_id
       WHERE wr.id = ?1 AND wr.workstream_id = ?2
         AND wr.mode = 'stateful' AND wr.status = 'running'
         AND wr.primary_workspace_id = p.primary_workspace_id
       LIMIT 1`,
      )
      .bind(request.workRequestId, request.workstreamId)
      .first<Record<string, unknown>>()
      .then((row) => {
        if (!row) return null;
        return {
          workstreamId: String(row.workstreamId),
          workRequestId: String(row.workRequestId),
          workspaceId: String(row.workspaceId),
          checkoutId: String(row.checkoutId),
          leaseId: String(row.leaseId),
          fencingToken: number(row.fencingToken),
          expectedRevision: String(row.expectedRevision),
        };
      });
    if (
      !statefulLease ||
      (request.workspaceId && request.workspaceId !== statefulLease.workspaceId)
    )
      return null;
  }

  const hasV7CandidateRows = await db
    .prepare(
      `SELECT EXISTS (
         SELECT 1 FROM workspace_project_grants g
         JOIN execution_workspaces ew ON ew.id = g.workspace_id
         JOIN workspace_runtime_identities wri ON wri.workspace_id = ew.id AND wri.revoked_at IS NULL
         JOIN workspace_worker_inventory i ON i.workspace_id = ew.id AND i.status != 'removed'
        WHERE g.project_id = ?1 AND g.status = 'active'
          AND (g.expires_at IS NULL OR g.expires_at > ?2) AND ew.status = 'online'
       ) AS has_v7`,
    )
    .bind(request.projectId, now.toISOString())
    .first<{ has_v7: number }>()
    .then((row) => Number(row?.has_v7 ?? 0) === 1)
    .catch(() => false);

  // A project with eligible V7 inventory never reads V6 Worker bindings for
  // candidate selection. The compatibility query is a fallback only when no
  // online, granted Workspace currently has V7 inventory.
  const legacyRows = hasV7CandidateRows
    ? { results: [] as Row[] }
    : await db
        .prepare(
          `SELECT g.id AS grant_id, g.project_id, g.workspace_id, g.status AS grant_status,
            g.scope, g.repository_mappings_json, g.path_mappings_json,
            g.allowed_worker_ids_json, g.allowed_worker_capabilities_json,
            g.allowed_permissions_json, g.network_policy_json,
            g.concurrency_json, g.requires_step_up, g.expires_at,
            ep.allowed_configured_worker_ids_json,
            ep.allowed_worker_type_ids_json,
            ep.allowed_providers_json,
            ep.allowed_models_json,
            ew.name AS workspace_name, ew.owner_user_id, ew.status AS workspace_status,
            wri.id AS runtime_identity_id,
            cw.id AS configured_worker_id, cw.worker_type_id,
            wt.display_name AS publisher, wv.version AS worker_version,
            wv.capabilities_json, wv.permissions_json,
            b.package_status AS package_status, b.enabled AS desired_enabled,
            b.desired_version_policy AS version_policy,
            c.id AS credential_id, c.state AS credential_status,
            c.sharing_policy AS credential_sharing_policy,
            c.owner_user_id AS credential_owner_user_id,
            c.auth_type, c.provider_metadata_json,
            cw.concurrency_limit AS configured_concurrency_limit,
            (SELECT COUNT(*) FROM worker_assignments wa
             WHERE wa.execution_workspace_id = g.workspace_id
               AND (wa.configured_worker_id = cw.id OR
                    (wa.configured_worker_id IS NULL AND wa.worker_id = cw.worker_type_id))
               AND wa.status IN ('created', 'dispatched', 'acknowledged', 'running')) AS active_assignments
     FROM workspace_project_grants g
     LEFT JOIN project_execution_preferences pep ON pep.project_id = g.project_id
     LEFT JOIN workstream_execution_policies ep ON ep.workstream_id = ?4
     JOIN execution_workspaces ew ON ew.id = g.workspace_id
     JOIN workspace_runtime_identities wri ON wri.workspace_id = ew.id AND wri.revoked_at IS NULL
     JOIN worker_workspace_bindings b ON b.workspace_id = ew.id AND b.enabled = 1
     JOIN configured_workers cw ON cw.id = b.worker_id AND cw.status = 'active'
     JOIN workers wt ON wt.id = cw.worker_type_id AND wt.status = 'active'
     JOIN worker_versions wv ON wv.worker_id = cw.worker_type_id AND wv.is_revoked = 0
       AND (b.desired_version_policy IN ('latest', 'stable') OR b.desired_version_policy = wv.version)
     JOIN workspace_worker_credentials c ON c.worker_id = cw.id AND c.workspace_id = ew.id
     WHERE g.project_id = ?1 AND g.status = 'active'
       AND (g.expires_at IS NULL OR g.expires_at > ?3)
       AND ew.status = 'online'
     ORDER BY CASE WHEN c.owner_user_id = ?2 THEN 0 ELSE 1 END,
              active_assignments, ew.id, cw.id`,
        )
        .bind(
          request.projectId,
          request.requesterUserId,
          now.toISOString(),
          request.workstreamId ?? "",
        )
        .all<Row>()
        .catch(() => ({ results: [] as Row[] }));

  const v7Rows = await db
    .prepare(
      `SELECT g.id AS grant_id, g.project_id, g.workspace_id, g.status AS grant_status,
            g.scope, g.repository_mappings_json, g.path_mappings_json,
            g.allowed_worker_ids_json, g.allowed_worker_capabilities_json,
            g.allowed_permissions_json, g.network_policy_json,
            g.concurrency_json, g.requires_step_up, g.expires_at,
            ep.allowed_configured_worker_ids_json,
            ep.allowed_worker_type_ids_json,
            ep.allowed_providers_json,
            ep.allowed_models_json,
            ew.name AS workspace_name, ew.owner_user_id, ew.status AS workspace_status,
            wri.id AS runtime_identity_id,
            i.worker_id, i.worker_type_id,
            COALESCE(i.adapter_version, '1.0.0') AS worker_version,
            i.capabilities_json, i.local_permissions_summary_json AS local_permissions_json,
            i.allowed_models_json AS worker_allowed_models_json, i.default_model AS worker_default_model,
            i.status AS local_worker_status,
            vs.state AS cloud_scheduling_state,
            vs.cloud_concurrency_limit,
            i.credential_status AS credential_status,
            i.worker_type_id AS provider,
            i.local_concurrency_limit AS local_concurrency_limit,
            (SELECT COUNT(*) FROM worker_assignments wa
             WHERE wa.execution_workspace_id = g.workspace_id
               AND (wa.configured_worker_id = i.worker_id OR
                    (wa.configured_worker_id IS NULL AND wa.worker_id = i.worker_type_id))
               AND wa.status IN ('created', 'dispatched', 'acknowledged', 'running')) AS active_assignments
     FROM workspace_project_grants g
     LEFT JOIN project_execution_preferences pep ON pep.project_id = g.project_id
     LEFT JOIN workstream_execution_policies ep ON ep.workstream_id = ?4
     JOIN execution_workspaces ew ON ew.id = g.workspace_id
     JOIN workspace_runtime_identities wri ON wri.workspace_id = ew.id AND wri.revoked_at IS NULL
     JOIN workspace_worker_inventory i ON i.workspace_id = ew.id AND i.status != 'removed'
     JOIN v7_worker_scheduling vs ON vs.worker_id = i.worker_id
     WHERE g.project_id = ?1 AND g.status = 'active'
       AND (g.expires_at IS NULL OR g.expires_at > ?3)
       AND ew.status = 'online'
     ORDER BY CASE WHEN i.owner_user_id = ?2 THEN 0 ELSE 1 END,
              active_assignments, ew.id, i.worker_id`,
    )
    .bind(
      request.projectId,
      request.requesterUserId,
      now.toISOString(),
      request.workstreamId ?? "",
    )
    .all<Row>()
    .catch(() => ({ results: [] as Row[] }));

  const excluded = new Set(request.excludeIndependenceKeys ?? []);
  const rejected: Array<Record<string, unknown>> = [];
  const seenConfigured = new Set<string>();
  const combined: Row[] = [];
  for (const row of v7Rows.results ?? []) {
    const id = String(row.configured_worker_id ?? row.worker_id ?? "");
    if (id) seenConfigured.add(id);
    combined.push(row);
  }
  for (const row of legacyRows.results ?? []) {
    const id = String(row.configured_worker_id ?? row.worker_id ?? "");
    if (!seenConfigured.has(id)) {
      combined.push(row);
    }
  }
  const candidates = combined.sort((left, right) => {
    const load =
      number(left.active_assignments) - number(right.active_assignments);
    return (
      load ||
      String(left.workspace_id).localeCompare(String(right.workspace_id))
    );
  });
  for (const row of candidates) {
    const workspaceId = String(row.workspace_id);
    const configuredWorkerId = String(
      row.configured_worker_id ?? row.worker_id,
    );
    const workerTypeId = String(row.worker_type_id ?? row.worker_id);
    const workerId = configuredWorkerId;
    const accountId =
      row.account_id == null ? undefined : String(row.account_id);
    const credentialId =
      row.credential_id == null ? undefined : String(row.credential_id);
    const isV7 = row.local_worker_status != null;
    const credentialOwnerUserId =
      row.credential_owner_user_id == null
        ? row.account_owner_user_id == null
          ? undefined
          : String(row.account_owner_user_id)
        : String(row.credential_owner_user_id);
    const capabilities = strings(row.capabilities_json).map((value) =>
      value.toLowerCase(),
    );
    const requiredCapabilities = request.capabilities.map((value) =>
      value.toLowerCase(),
    );
    const grantCapabilities = strings(row.allowed_worker_capabilities_json).map(
      (value) => value.toLowerCase(),
    );
    const providerMetadata = object(row.provider_metadata_json);
    const provider = String(
      row.provider ??
        providerMetadata.provider ??
        providerMetadata.providerId ??
        "unknown",
    );
    const selectedModel =
      request.model ??
      (isV7 && typeof row.worker_default_model === "string"
        ? row.worker_default_model
        : undefined);
    const independenceKey = `${provider}:${workerTypeId}`;
    const concurrency = object(row.concurrency_json);
    const maxConcurrent = Math.min(
      number(
        row.local_concurrency_limit,
        number(row.configured_concurrency_limit, 1024),
      ),
      number(row.cloud_concurrency_limit, 1024),
      number(concurrency.maxConcurrentAssignments, 1024),
    );

    const reject = (reason: string) =>
      rejected.push({ workspaceId, workerId, accountId, reason });
    if (statefulLease && workspaceId !== statefulLease.workspaceId) {
      reject("stateful_primary_workspace_required");
      continue;
    }
    if (String(row.workspace_status) !== "online") {
      reject("workspace_offline");
      continue;
    }
    if (String(row.grant_status) !== "active") {
      reject("grant_inactive");
      continue;
    }
    if (isV7 && row.cloud_scheduling_state === "draining") {
      reject("cloud_scheduling_draining");
      continue;
    }
    if (isV7 && row.cloud_scheduling_state !== "enabled") {
      reject("cloud_scheduling_disabled");
      continue;
    }
    if (isV7 && String(row.local_worker_status) !== "ready") {
      reject("local_worker_not_ready");
      continue;
    }
    const credentialStatus = String(
      row.credential_status ?? row.account_status ?? "unknown",
    );
    if (credentialStatus !== "ready" && credentialStatus !== "not_required") {
      reject(isV7 ? "local_credential_unavailable" : "credential_unavailable");
      continue;
    }
    const credentialSharingPolicy = String(
      row.credential_sharing_policy ?? "explicit_project",
    );
    if (
      !isV7 &&
      credentialSharingPolicy === "private_only" &&
      credentialOwnerUserId !== request.requesterUserId
    ) {
      reject("credential_private_to_owner");
      continue;
    }
    if (request.workspaceId && request.workspaceId !== workspaceId) {
      reject("explicit_workspace_mismatch");
      continue;
    }
    const explicitConfiguredWorkerId =
      request.configuredWorkerId ?? request.workerId;
    if (
      explicitConfiguredWorkerId &&
      explicitConfiguredWorkerId !== configuredWorkerId
    ) {
      reject("explicit_worker_mismatch");
      continue;
    }
    if (request.accountId && request.accountId !== accountId) {
      reject("explicit_account_mismatch");
      continue;
    }
    if (
      !isV7 &&
      (String(row.package_status ?? row.installation_status) !== "ready" ||
        Number(row.desired_enabled) !== 1)
    ) {
      reject("worker_not_ready");
      continue;
    }
    if (
      !requiredCapabilities.every((capability) =>
        capabilities.includes(capability),
      )
    ) {
      reject("worker_capability_missing");
      continue;
    }
    if (
      isV7 &&
      grantCapabilities.length > 0 &&
      !requiredCapabilities.every((capability) =>
        grantCapabilities.includes(capability),
      )
    ) {
      reject("capability_not_allowed_by_grant");
      continue;
    }
    if (
      !isV7 &&
      grantCapabilities.some((capability) => !capabilities.includes(capability))
    ) {
      reject("grant_capability_not_declared");
      continue;
    }
    if (!allowedByJson(row, "allowed_worker_ids_json", workerId)) {
      reject("worker_not_allowed_by_grant");
      continue;
    }
    if (
      !allowedByJson(
        row,
        "allowed_configured_worker_ids_json",
        configuredWorkerId,
      )
    ) {
      reject("worker_not_allowed_by_workstream");
      continue;
    }
    if (!allowedByJson(row, "allowed_worker_type_ids_json", workerTypeId)) {
      reject("worker_type_not_allowed_by_workstream");
      continue;
    }
    if (!allowedByJson(row, "allowed_providers_json", provider)) {
      reject("provider_not_allowed_by_workstream");
      continue;
    }
    const allowedModels = strings(row.allowed_models_json);
    if (
      allowedModels.length > 0 &&
      (!selectedModel || !allowedModels.includes(selectedModel))
    ) {
      reject("model_not_allowed_by_workstream");
      continue;
    }
    const workerAllowedModels = strings(row.worker_allowed_models_json);
    if (
      selectedModel &&
      workerAllowedModels.length > 0 &&
      !workerAllowedModels.includes(selectedModel)
    ) {
      reject("model_not_supported_by_worker");
      continue;
    }
    if (excluded.has(independenceKey)) {
      reject("provider_independence_conflict");
      continue;
    }
    if (number(row.active_assignments) >= maxConcurrent) {
      reject("configured_worker_concurrency_limit");
      continue;
    }
    if (
      selectedModel &&
      providerMetadata.models &&
      Array.isArray(providerMetadata.models) &&
      !providerMetadata.models.includes(selectedModel)
    ) {
      reject("model_not_supported_by_account");
      continue;
    }

    const grantPermissions = strings(row.allowed_permissions_json);
    const workerPermissions = strings(
      row.local_permissions_json ?? row.permissions_json,
    );
    const permissions = resolveEffectivePermissions({
      projectMemberPermissions: projectPermissions(membership.role),
      workspaceGrantPermissions: grantPermissions,
      workerManifestPermissions: workerPermissions,
      workspaceLocalPermissions: workerPermissions,
      projectPolicyPermissions: projectPermissions(membership.role),
    });
    if (permissions.length === 0) {
      reject("effective_permission_intersection_empty");
      continue;
    }
    const snapshotAt = now.toISOString();
    const permissionSnapshot = {
      projectId: request.projectId,
      workspaceId,
      configuredWorkerId,
      workerTypeId,
      credentialId,
      credentialOwnerUserId,
      grantId: String(row.grant_id),
      requesterUserId: request.requesterUserId,
      scope: String(row.scope),
      permissions,
      repositoryMappings: parseJsonValue(row.repository_mappings_json),
      pathMappings: parseJsonValue(row.path_mappings_json),
      networkPolicy: object(row.network_policy_json),
      concurrency,
      workstreamPolicy: {
        allowedConfiguredWorkerIds: strings(
          row.allowed_configured_worker_ids_json,
        ),
        allowedWorkerTypeIds: strings(row.allowed_worker_type_ids_json),
        allowedProviders: strings(row.allowed_providers_json),
        allowedModels,
      },
      ...(request.expectedRevision
        ? { checkpointRevision: request.expectedRevision }
        : {}),
      snapshotAt,
    };
    return {
      projectId: request.projectId,
      workspaceId,
      workspaceRuntimeIdentityId: String(row.runtime_identity_id),
      workspaceProjectGrantId: String(row.grant_id),
      configuredWorkerId,
      workerTypeId,
      workerId,
      workerVersion: String(row.worker_version),
      accountId,
      credentialId,
      credentialOwnerUserId,
      model: selectedModel ?? null,
      effectivePermissions: permissions,
      permissionSnapshot,
      selectionExplanation: {
        projectMembership: membership.role,
        workspace: {
          id: workspaceId,
          status: row.workspace_status,
          grantId: row.grant_id,
        },
        worker: {
          id: configuredWorkerId,
          workerTypeId,
          version: row.worker_version,
          status:
            row.local_worker_status ??
            row.package_status ??
            row.installation_status,
        },
        ...(isV7
          ? { localAuthentication: { status: credentialStatus } }
          : {
              credential: {
                id: credentialId,
                owner: credentialOwnerUserId === request.requesterUserId,
                provider,
              },
            }),
        filters: [
          "project_authorized",
          "grant_active",
          "workspace_online",
          ...(isV7
            ? [
                "workspace_worker_owned",
                "local_worker_ready",
                "cloud_scheduling_enabled",
              ]
            : ["configured_worker_bound", "package_ready", "credential_ready"]),
          "permissions_intersected",
          "capacity_available",
          ...(statefulLease
            ? ["primary_workspace", "checkout_ready", "lease_active"]
            : []),
        ],
        rejectedAlternatives: rejected,
      },
      executionClass,
      ...(statefulLease
        ? {
            workstreamId: statefulLease.workstreamId,
            workRequestId: statefulLease.workRequestId,
            checkoutId: statefulLease.checkoutId,
            leaseId: statefulLease.leaseId,
            fencingToken: statefulLease.fencingToken,
            expectedRevision: statefulLease.expectedRevision,
          }
        : request.expectedRevision
          ? { expectedRevision: request.expectedRevision }
          : {}),
    };
  }
  return null;
}

function parseJsonValue(value: unknown): unknown {
  if (typeof value !== "string") return value ?? null;
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}
