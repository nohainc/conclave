import { resolveEffectivePermissions } from "@conclave/core";

export interface ProjectExecutionSelectionRequest {
  readonly projectId: string;
  readonly requesterUserId: string;
  readonly role: string;
  readonly capabilities: readonly string[];
  readonly workspaceId?: string;
  readonly workerId?: string;
  readonly excludeIndependenceKeys?: readonly string[];
  readonly model?: string;
  readonly executionClass?: "stateless_read" | "stateful_workstream";
  readonly workstreamId?: string;
  readonly workRequestId?: string;
  readonly expectedRevision?: string;
}

export interface V7ExecutionTarget {
  readonly projectId: string;
  readonly workspaceId: string;
  readonly workspaceRuntimeIdentityId: string;
  readonly workspaceProjectGrantId: string;
  /** Configured Worker identity selected for this assignment. */
  readonly workerId: string;
  /** Worker Type/catalog identity used to resolve the package. */
  readonly workerTypeId: string;
  readonly workerVersion: string;
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
): Promise<V7ExecutionTarget | null> {
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

  const v7Rows = await db
    .prepare(
      `SELECT g.id AS grant_id, g.project_id, g.workspace_id, g.status AS grant_status,
            g.scope, g.repository_mappings_json, g.path_mappings_json,
            g.allowed_worker_ids_json, g.allowed_worker_capabilities_json,
            g.allowed_permissions_json, g.network_policy_json,
            g.concurrency_json, g.requires_step_up, g.expires_at,
            ep.allowed_configured_worker_ids_json AS allowed_workspace_worker_ids_json,
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
               AND wa.workspace_worker_id = i.worker_id
               AND wa.status IN ('created', 'dispatched', 'acknowledged', 'running')) AS active_assignments
     FROM workspace_project_grants g
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
  const candidates = [...(v7Rows.results ?? [])].sort((left, right) => {
    const load =
      number(left.active_assignments) - number(right.active_assignments);
    return (
      load ||
      String(left.workspace_id).localeCompare(String(right.workspace_id))
    );
  });
  for (const row of candidates) {
    const workspaceId = String(row.workspace_id);
    const workerId = String(row.worker_id);
    const workerTypeId = String(row.worker_type_id);
    const credentialStatus = String(row.credential_status ?? "unknown");
    const capabilities = strings(row.capabilities_json).map((value) =>
      value.toLowerCase(),
    );
    const requiredCapabilities = request.capabilities.map((value) =>
      value.toLowerCase(),
    );
    const grantCapabilities = strings(row.allowed_worker_capabilities_json).map(
      (value) => value.toLowerCase(),
    );
    const provider = String(row.provider ?? "unknown");
    const selectedModel =
      request.model ??
      (typeof row.worker_default_model === "string"
        ? row.worker_default_model
        : undefined);
    const independenceKey = `${provider}:${workerTypeId}`;
    const concurrency = object(row.concurrency_json);
    const maxConcurrent = Math.min(
      number(row.local_concurrency_limit, 1024),
      row.cloud_concurrency_limit == null
        ? 1024
        : number(row.cloud_concurrency_limit, 1024),
      number(concurrency.maxConcurrentAssignments, 1024),
    );

    const reject = (reason: string) =>
      rejected.push({ workspaceId, workerId, reason });
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
    if (row.cloud_scheduling_state === "draining") {
      reject("cloud_scheduling_draining");
      continue;
    }
    if (row.cloud_scheduling_state !== "enabled") {
      reject("cloud_scheduling_disabled");
      continue;
    }
    if (String(row.local_worker_status) !== "ready") {
      reject("local_worker_not_ready");
      continue;
    }
    if (credentialStatus !== "ready" && credentialStatus !== "not_required") {
      reject("local_credential_unavailable");
      continue;
    }
    if (request.workspaceId && request.workspaceId !== workspaceId) {
      reject("explicit_workspace_mismatch");
      continue;
    }
    if (
      request.workerId &&
      request.workerId !== workerId
    ) {
      reject("explicit_worker_mismatch");
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
      grantCapabilities.length > 0 &&
      !requiredCapabilities.every((capability) =>
        grantCapabilities.includes(capability),
      )
    ) {
      reject("capability_not_allowed_by_grant");
      continue;
    }
    if (!allowedByJson(row, "allowed_worker_ids_json", workerId)) {
      reject("worker_not_allowed_by_grant");
      continue;
    }
    if (
      !allowedByJson(
        row,
        "allowed_workspace_worker_ids_json",
        workerId,
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
      reject("worker_concurrency_limit");
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
      configuredWorkerId: workerId,
      workerId,
      workerTypeId,
      grantId: String(row.grant_id),
      requesterUserId: request.requesterUserId,
      scope: String(row.scope),
      permissions,
      repositoryMappings: parseJsonValue(row.repository_mappings_json),
      pathMappings: parseJsonValue(row.path_mappings_json),
      networkPolicy: object(row.network_policy_json),
      concurrency,
      workstreamPolicy: {
        allowedWorkerIds: strings(row.allowed_workspace_worker_ids_json),
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
      workerId,
      workerTypeId,
      workerVersion: String(row.worker_version),
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
          id: workerId,
          workerTypeId,
          version: row.worker_version,
          status: row.local_worker_status,
        },
        localAuthentication: { status: credentialStatus },
        filters: [
          "project_authorized",
          "grant_active",
          "workspace_online",
          "workspace_worker_owned",
          "local_worker_ready",
          "cloud_scheduling_enabled",
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
