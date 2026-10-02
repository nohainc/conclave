import {
  resolveEffectivePermissions,
  type WorkstreamBindingId,
} from "@conclave/core";

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
  /** Read-only capability policy independent of Workstream lease ownership. */
  readonly readOnly?: boolean;
  readonly workstreamId?: string;
  readonly workRequestId?: string;
  readonly workBindingId?: WorkstreamBindingId;
}

export interface ExecutionTarget {
  readonly projectId: string;
  readonly workspaceId: string;
  readonly workspaceRuntimeIdentityId: string;
  readonly workspaceProjectGrantId: string;
  /** Local Worker identity selected for this assignment. */
  readonly workerId: string;
  /** Product Worker Type ID reported by Workspace and selected by policy. */
  readonly workerTypeId: string;
  readonly engineVersion: string;
  readonly profileDefinitionId: string;
  readonly profileReleaseVersion: number;
  readonly providerToolName: string | null;
  readonly providerToolVersion: string | null;
  readonly model: string | null;
  readonly effectivePermissions: readonly string[];
  readonly permissionSnapshot: Record<string, unknown>;
  readonly selectionExplanation: Record<string, unknown>;
  readonly executionClass: "stateless_read" | "stateful_workstream";
  readonly readOnly: boolean;
  readonly workstreamId?: string;
  readonly workRequestId?: string;
  readonly leaseId?: string;
  readonly fencingToken?: number;
}

export type WorkspaceLiveCheck = (
  workspaceId: string,
  runtimeIdentityId: string,
) => Promise<boolean>;

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
 * Resolves an execution target for a Project. The returned explanation is
 * persisted with the assignment.
 */
export async function selectProjectExecutionTarget(
  db: D1Database,
  request: ProjectExecutionSelectionRequest,
  now = new Date(),
  isWorkspaceLive?: WorkspaceLiveCheck,
): Promise<ExecutionTarget | null> {
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
    leaseId: string;
    fencingToken: number;
  } | null = null;
  if (executionClass === "stateful_workstream") {
    if (!request.workstreamId || !request.workRequestId) return null;
    statefulLease = await db
      .prepare(
        `SELECT wr.workstream_id AS workstreamId, wr.id AS workRequestId,
              wr.primary_workspace_id AS workspaceId,
              l.id AS leaseId, l.fencing_token AS fencingToken
       FROM work_requests wr
       JOIN workstream_runtime_leases l ON l.work_request_id = wr.id
        AND l.workstream_id = wr.workstream_id AND l.status = 'active'
       WHERE wr.id = ?1 AND wr.workstream_id = ?2
         AND wr.mode = 'stateful' AND wr.status = 'running'
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
          leaseId: String(row.leaseId),
          fencingToken: number(row.fencingToken),
        };
      });
    if (
      !statefulLease ||
      (request.workspaceId && request.workspaceId !== statefulLease.workspaceId)
    )
      return null;
  }

  const candidateRows = await db
    .prepare(
      `SELECT g.id AS grant_id, g.project_id, g.workspace_id, g.status AS grant_status,
            g.allowed_worker_ids_json, g.allowed_worker_capabilities_json,
            g.allowed_permissions_json, g.network_policy_json,
            g.concurrency_json, g.expires_at,
            ep.allowed_worker_type_ids_json,
            ep.allowed_models_json,
            usage.config_json AS workstream_work_config_json,
            wr.snapshot_json AS work_request_snapshot_json,
            ew.name AS workspace_name, ew.owner_user_id, ew.status AS workspace_status,
            wri.id AS runtime_identity_id,
            i.worker_id, i.worker_type_id,
            i.engine_version AS engine_version,
            i.profile_definition_id, i.profile_release_version,
            i.provider_tool_name,
            i.provider_tool_version,
            i.capabilities_json,
            i.activation_state AS local_worker_activation_state,
            i.readiness_state AS local_worker_readiness_state,
            vs.state AS cloud_scheduling_state,
            vs.cloud_concurrency_limit,
            i.local_concurrency_limit AS local_concurrency_limit,
            (SELECT COUNT(*) FROM worker_assignments wa
             WHERE wa.execution_workspace_id = g.workspace_id
               AND wa.workspace_worker_id = i.worker_id
               AND wa.status IN ('created', 'dispatched', 'acknowledged', 'running')) AS active_assignments
     FROM workspace_project_grants g
     LEFT JOIN workstream_execution_policies ep ON ep.workstream_id = ?4
     JOIN execution_workspaces ew ON ew.id = g.workspace_id
     LEFT JOIN workstream_work_configs usage ON usage.workstream_id = ?4
     LEFT JOIN work_requests wr ON wr.id = ?5 AND wr.workstream_id = ?4
     JOIN workspace_runtime_identities wri ON wri.workspace_id = ew.id AND wri.revoked_at IS NULL
     JOIN workspace_worker_inventory i ON i.workspace_id = ew.id
     JOIN worker_scheduling vs ON vs.worker_id = i.worker_id
     WHERE g.project_id = ?1 AND g.status = 'active'
       AND (g.expires_at IS NULL OR g.expires_at > ?3)
       AND ew.status <> 'revoked'
       ${isWorkspaceLive ? "" : "AND ew.status = 'online'"}
     ORDER BY CASE WHEN i.owner_user_id = ?2 THEN 0 ELSE 1 END,
              active_assignments, ew.id, i.worker_id`,
    )
    .bind(
      request.projectId,
      request.requesterUserId,
      now.toISOString(),
      request.workstreamId ?? "",
      request.workRequestId ?? "",
    )
    .all<Row>()
    .catch(() => ({ results: [] as Row[] }));

  const excluded = new Set(request.excludeIndependenceKeys ?? []);
  const rejected: Array<Record<string, unknown>> = [];
  const liveWorkspaceChecks = new Map<string, Promise<boolean>>();
  const bindingFor = (row: Row): Record<string, unknown> => {
    const config = object(row.workstream_work_config_json);
    const configBindings =
      config.bindings && typeof config.bindings === "object"
        ? (config.bindings as Record<string, unknown>)
        : {};
    const snapshot = object(row.work_request_snapshot_json);
    const snapshotBindings =
      snapshot.resolvedBindings && typeof snapshot.resolvedBindings === "object"
        ? (snapshot.resolvedBindings as Record<string, unknown>)
        : {};
    const bindings = request.workRequestId ? snapshotBindings : configBindings;
    const raw = request.workBindingId
      ? bindings[request.workBindingId]
      : undefined;
    return raw && typeof raw === "object" && !Array.isArray(raw)
      ? (raw as Record<string, unknown>)
      : {};
  };
  const candidates = [...(candidateRows.results ?? [])].sort((left, right) => {
    const preference = (row: Row): number => {
      const value = bindingFor(row);
      const preferred = [
        ...(typeof value.workerId === "string" ? [value.workerId] : []),
        ...(typeof value.fallbackWorkerId === "string"
          ? [value.fallbackWorkerId]
          : []),
      ];
      const index = preferred.indexOf(String(row.worker_id));
      return index < 0 ? Number.MAX_SAFE_INTEGER : index;
    };
    const configuredFirst = preference(left) - preference(right);
    if (configuredFirst) return configuredFirst;
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
    const binding = bindingFor(row);
    const hasBinding = Object.keys(binding).length > 0;
    const preferredWorkerIds = [
      ...(typeof binding.workerId === "string" ? [binding.workerId] : []),
      ...(typeof binding.fallbackWorkerId === "string"
        ? [binding.fallbackWorkerId]
        : []),
    ];
    const capabilities = strings(row.capabilities_json).map((value) =>
      value.toLowerCase(),
    );
    const requiredCapabilities = request.capabilities.map((value) =>
      value.toLowerCase(),
    );
    const grantCapabilities = strings(row.allowed_worker_capabilities_json).map(
      (value) => value.toLowerCase(),
    );
    const selectedModel =
      request.workstreamId &&
      typeof binding.model === "string" &&
      binding.model.trim().length > 0
        ? binding.model
        : (request.model ??
          (typeof binding.model === "string" ? binding.model : undefined));
    const independenceKey = workerTypeId;
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
    if (!isWorkspaceLive && String(row.workspace_status) !== "online") {
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
    if (String(row.local_worker_activation_state) !== "enabled") {
      reject("local_worker_disabled");
      continue;
    }
    if (String(row.local_worker_readiness_state) !== "ready") {
      reject("local_worker_not_ready");
      continue;
    }
    if (
      typeof row.engine_version !== "string" ||
      !row.engine_version ||
      typeof row.profile_definition_id !== "string" ||
      !row.profile_definition_id ||
      !Number.isSafeInteger(Number(row.profile_release_version)) ||
      Number(row.profile_release_version) < 1
    ) {
      reject("engine_profile_unavailable");
      continue;
    }
    if (request.workstreamId && !hasBinding) {
      reject("workstream_step_binding_missing");
      continue;
    }
    if (request.workspaceId && request.workspaceId !== workspaceId) {
      reject("explicit_workspace_mismatch");
      continue;
    }
    if (
      request.workstreamId &&
      (preferredWorkerIds.length === 0 ||
        !preferredWorkerIds.includes(workerId))
    ) {
      reject(
        preferredWorkerIds.length === 0
          ? "no_worker_selected_for_step"
          : "worker_not_selected_for_step",
      );
      continue;
    }
    if (request.workerId && request.workerId !== workerId) {
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
    if (!allowedByJson(row, "allowed_worker_type_ids_json", workerTypeId)) {
      reject("worker_type_not_allowed_by_workstream");
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
    if (excluded.has(independenceKey)) {
      reject("provider_independence_conflict");
      continue;
    }
    if (number(row.active_assignments) >= maxConcurrent) {
      reject("worker_concurrency_limit");
      continue;
    }

    const grantPermissions = strings(row.allowed_permissions_json);
    // Local execution permissions stay on the Workspace. Cloud intersects
    // project membership and grant policy; the Worker enforces its own local
    // permission boundary when accepting/executing the assignment.
    const workerPermissions = grantPermissions;
    const resolvedPermissions = resolveEffectivePermissions({
      projectMemberPermissions: projectPermissions(membership.role),
      workspaceGrantPermissions: grantPermissions,
      workerManifestPermissions: workerPermissions,
      workspaceLocalPermissions: workerPermissions,
      projectPolicyPermissions: projectPermissions(membership.role),
    });
    // Read-only steps may keep the active Workstream lease so they inspect its
    // current filesystem, while dropping repository writes. Test alone retains
    // shell execution so it can run validation commands inside the read-only
    // provider sandbox.
    const canRunTestCommands = request.capabilities.includes("test_execution");
    const permissions =
      executionClass === "stateless_read" || request.readOnly === true
        ? resolvedPermissions.filter(
            (permission) =>
              permission !== "repository:write" &&
              (permission !== "shell:execute" || canRunTestCommands),
          )
        : resolvedPermissions;
    if (permissions.length === 0) {
      reject("effective_permission_intersection_empty");
      continue;
    }
    let workspaceIsLive = false;
    if (isWorkspaceLive) {
      const runtimeIdentityId = String(row.runtime_identity_id);
      const key = `${workspaceId}:${runtimeIdentityId}`;
      let liveCheck = liveWorkspaceChecks.get(key);
      if (!liveCheck) {
        liveCheck = isWorkspaceLive(workspaceId, runtimeIdentityId).catch(
          () => false,
        );
        liveWorkspaceChecks.set(key, liveCheck);
      }
      workspaceIsLive = await liveCheck;
      if (!workspaceIsLive) {
        reject("workspace_offline");
        continue;
      }
    }
    const snapshotAt = now.toISOString();
    const permissionSnapshot = {
      projectId: request.projectId,
      workspaceId,
      workerId,
      workerTypeId,
      grantId: String(row.grant_id),
      engineVersion: String(row.engine_version),
      profileDefinitionId: String(row.profile_definition_id),
      profileReleaseVersion: Number(row.profile_release_version),
      model: selectedModel ?? null,
      providerToolName:
        typeof row.provider_tool_name === "string"
          ? row.provider_tool_name
          : null,
      providerToolVersion:
        typeof row.provider_tool_version === "string"
          ? row.provider_tool_version
          : null,
      requesterUserId: request.requesterUserId,
      permissions,
      networkPolicy: object(row.network_policy_json),
      concurrency,
      workstreamPolicy: {
        allowedWorkerTypeIds: strings(row.allowed_worker_type_ids_json),
        allowedModels,
      },
      snapshotAt,
    };
    return {
      projectId: request.projectId,
      workspaceId,
      workspaceRuntimeIdentityId: String(row.runtime_identity_id),
      workspaceProjectGrantId: String(row.grant_id),
      workerId,
      workerTypeId,
      engineVersion: String(row.engine_version),
      profileDefinitionId: String(row.profile_definition_id),
      profileReleaseVersion: Number(row.profile_release_version),
      providerToolName:
        typeof row.provider_tool_name === "string"
          ? row.provider_tool_name
          : null,
      providerToolVersion:
        typeof row.provider_tool_version === "string"
          ? row.provider_tool_version
          : null,
      model: selectedModel ?? null,
      effectivePermissions: permissions,
      permissionSnapshot,
      selectionExplanation: {
        projectMembership: membership.role,
        workspace: {
          id: workspaceId,
          status: isWorkspaceLive ? "online" : row.workspace_status,
          connectionSource: isWorkspaceLive ? "workspace_gateway" : "database",
          grantId: row.grant_id,
        },
        worker: {
          id: workerId,
          workerTypeId,
          engineVersion: row.engine_version,
          profileDefinitionId: row.profile_definition_id,
          profileReleaseVersion: row.profile_release_version,
          providerToolName:
            typeof row.provider_tool_name === "string"
              ? row.provider_tool_name
              : null,
          providerToolVersion:
            typeof row.provider_tool_version === "string"
              ? row.provider_tool_version
              : null,
          activationState: row.local_worker_activation_state,
          readinessState: row.local_worker_readiness_state,
          workBindingId: request.workBindingId ?? null,
          selection: preferredWorkerIds.includes(workerId)
            ? "configured_preference"
            : "eligible_fallback",
        },
        filters: [
          "project_authorized",
          "grant_active",
          "workspace_online",
          "workspace_worker_owned",
          "local_worker_ready",
          "cloud_scheduling_enabled",
          "permissions_intersected",
          "capacity_available",
          ...(statefulLease ? ["primary_workspace", "lease_active"] : []),
        ],
        rejectedAlternatives: rejected,
      },
      executionClass,
      readOnly:
        executionClass === "stateless_read" || request.readOnly === true,
      ...(statefulLease
        ? {
            workstreamId: statefulLease.workstreamId,
            workRequestId: statefulLease.workRequestId,
            leaseId: statefulLease.leaseId,
            fencingToken: statefulLease.fencingToken,
          }
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
