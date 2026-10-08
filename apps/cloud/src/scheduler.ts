import { spaceMemberPermissions, spaceWorkAllowed } from "@conclave/security";
import {
  EXECUTION_PERMISSIONS,
  isWorkspaceSpaceGrantStatus,
  resolveExecutionPermissions,
  validateWorkspaceConcurrencyPolicy,
  validateWorkspaceGrantCapabilities,
  validateWorkspaceGrantPermissions,
  validateWorkspaceGrantWorkerIds,
  validateWorkspaceNetworkPolicy,
  type ThreadBindingId,
} from "@conclave/core";

export interface SpaceExecutionSelectionRequest {
  readonly spaceId: string;
  readonly requesterUserId: string;
  readonly role: string;
  readonly capabilities: readonly string[];
  readonly workspaceId?: string;
  readonly workerId?: string;
  readonly excludeIndependenceKeys?: readonly string[];
  readonly model?: string;
  readonly reasoningEffort?: string;
  readonly executionClass?: "stateless_read" | "stateful_thread";
  /** Read-only capability policy independent of Thread lease ownership. */
  readonly readOnly?: boolean;
  readonly threadId?: string;
  readonly workRequestId?: string;
  readonly workBindingId?: ThreadBindingId;
}

export interface ExecutionTarget {
  readonly spaceId: string;
  readonly workspaceId: string;
  readonly workspaceRuntimeIdentityId: string;
  readonly workspaceSpaceGrantId: string;
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
  readonly reasoningEffort?: string | null;
  readonly effectivePermissions: readonly string[];
  readonly permissionSnapshot: Record<string, unknown>;
  readonly selectionExplanation: Record<string, unknown>;
  readonly executionClass: "stateless_read" | "stateful_thread";
  readonly readOnly: boolean;
  readonly threadId?: string;
  readonly workRequestId?: string;
  readonly conversationId?: string;
  readonly baseContextRevision?: number;
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

function parsedGrantJson<T>(
  value: unknown,
  validate: (parsed: unknown) => parsed is T,
): T | null {
  if (typeof value !== "string") return null;
  try {
    const parsed: unknown = JSON.parse(value);
    return validate(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function allowedByJson(row: Row, key: string, value: string): boolean {
  const allowed = strings(row[key]);
  return allowed.length === 0 || allowed.includes(value);
}

/**
 * Resolves an execution target for a Space. The returned explanation is
 * persisted with the assignment.
 */
export async function selectSpaceExecutionTarget(
  db: D1Database,
  request: SpaceExecutionSelectionRequest,
  now = new Date(),
  isWorkspaceLive?: WorkspaceLiveCheck,
): Promise<ExecutionTarget | null> {
  const membership = await db
    .prepare(
      `SELECT sm.role, s.settings_json AS settingsJson FROM space_memberships sm JOIN spaces s ON s.id = sm.space_id JOIN users u ON u.id = sm.user_id WHERE u.status = 'active' AND sm.space_id = ?1 AND sm.user_id = ?2`,
    )
    .bind(request.spaceId, request.requesterUserId)
    .first<{ role: string; settingsJson: string }>();
  if (!membership) return null;
  const rights = spaceMemberPermissions(
    membership.role,
    membership.settingsJson,
    request.requesterUserId,
  );
  let workflowId = request.workBindingId === "chat" ? "chat" : "direct";
  if (request.workRequestId) {
    const work = await db
      .prepare(
        "SELECT workflow_id AS workflowId, requested_by_user_id AS requesterUserId, thread_id AS threadId FROM work_requests WHERE id = ?1",
      )
      .bind(request.workRequestId)
      .first<{
        workflowId: string;
        requesterUserId: string;
        threadId: string;
      }>();
    if (
      !work ||
      work.requesterUserId !== request.requesterUserId ||
      work.threadId !== request.threadId
    )
      return null;
    workflowId = work.workflowId;
  }
  if (
    workflowId === "chat"
      ? !rights.chat
      : !rights.work || !spaceWorkAllowed(membership.settingsJson)
  )
    return null;

  if (request.threadId) {
    const thread = await db
      .prepare(
        `SELECT ws.space_id, ws.lead_user_id, ws.access_policy_json
           FROM threads ws
          WHERE ws.id = ?1`,
      )
      .bind(request.threadId)
      .first<Record<string, unknown>>();
    if (
      !thread ||
      typeof thread.space_id !== "string" ||
      thread.space_id !== request.spaceId
    ) {
      return null;
    }
    if (membership.role !== "owner") {
      const policy = object(thread.access_policy_json);
      const allowedUsers = Array.isArray(policy.allowedUserIds)
        ? policy.allowedUserIds.filter(
            (value): value is string => typeof value === "string",
          )
        : [];
      const allowedRoles = Array.isArray(policy.allowedSpaceRoles)
        ? policy.allowedSpaceRoles.filter(
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
        (allowedRoles.length > 0 && !allowedRoles.includes(membership.role)) ||
        !allowedPermissions.includes("execute")
      ) {
        return null;
      }
    }
  }

  const executionClass = request.executionClass ?? "stateless_read";
  let statefulLease: {
    threadId: string;
    workRequestId: string;
    workspaceId: string;
    leaseId: string;
    fencingToken: number;
  } | null = null;
  if (executionClass === "stateful_thread") {
    if (!request.threadId || !request.workRequestId) return null;
    statefulLease = await db
      .prepare(
        `SELECT wr.thread_id AS threadId, wr.id AS workRequestId,
              wr.primary_workspace_id AS workspaceId,
              l.id AS leaseId, l.fencing_token AS fencingToken
       FROM work_requests wr
       JOIN thread_runtime_leases l ON l.work_request_id = wr.id
        AND l.thread_id = wr.thread_id AND l.status = 'active'
       WHERE wr.id = ?1 AND wr.thread_id = ?2
         AND wr.mode = 'stateful' AND wr.status = 'running'
       LIMIT 1`,
      )
      .bind(request.workRequestId, request.threadId)
      .first<Record<string, unknown>>()
      .then((row) => {
        if (!row) return null;
        return {
          threadId: String(row.threadId),
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
      `SELECT g.id AS grant_id, g.space_id, g.workspace_id, g.status AS grant_status,
            g.allowed_worker_ids_json, g.allowed_worker_capabilities_json,
            g.allowed_permissions_json, g.network_policy_json,
            g.concurrency_json, g.expires_at,
            ep.allowed_worker_type_ids_json,
            ep.allowed_models_json,
            wr.snapshot_json AS work_request_snapshot_json,
            (SELECT conversation_id FROM conversation_work_requests WHERE work_request_id = wr.id) AS conversation_id,
            (SELECT cr.conversation_revision - 1 FROM conversation_work_requests cr WHERE cr.work_request_id = wr.id) AS base_context_revision,
            ew.name AS workspace_name, ew.owner_user_id, ew.status AS workspace_status,
            wri.id AS runtime_identity_id,
            i.worker_id, i.worker_type_id,
            catalog.display_name AS worker_display_name,
            catalog.lifecycle_state AS worker_catalog_lifecycle_state,
            catalog.visibility_state AS worker_catalog_visibility_state,
            catalog.release_stage AS worker_catalog_release_stage,
            profile_channel.channel AS workspace_tool_profile_channel,
            definition.profile_definition_id AS current_profile_definition_id,
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
     FROM workspace_space_grants g
     LEFT JOIN thread_execution_policies ep ON ep.thread_id = ?4
     JOIN execution_workspaces ew ON ew.id = g.workspace_id
     LEFT JOIN work_requests wr ON wr.id = ?5 AND wr.thread_id = ?4
     JOIN workspace_runtime_identities wri ON wri.workspace_id = ew.id AND wri.revoked_at IS NULL
     JOIN workspace_worker_inventory i ON i.workspace_id = ew.id
     LEFT JOIN workspace_tool_profile_channels profile_channel
       ON profile_channel.workspace_id = ew.id
     JOIN worker_catalog catalog
       ON catalog.worker_type_id = i.worker_type_id
      AND catalog.lifecycle_state = 'active'
      AND catalog.visibility_state = 'visible'
      AND (COALESCE(profile_channel.channel, 'stable') = 'testing'
           OR (COALESCE(profile_channel.channel, 'stable') = 'beta'
               AND catalog.release_stage IN ('beta', 'stable'))
           OR (COALESCE(profile_channel.channel, 'stable') = 'stable'
               AND catalog.release_stage = 'stable'))
     JOIN tool_profile_definitions definition
       ON definition.worker_type_id = catalog.worker_type_id
      AND definition.profile_definition_id = i.profile_definition_id
      AND definition.lifecycle_state = 'active'
     JOIN worker_scheduling vs ON vs.worker_id = i.worker_id
     WHERE g.space_id = ?1 AND g.status = 'active'
       AND (g.expires_at IS NULL OR g.expires_at > ?3)
       AND ew.status <> 'revoked'
       ${isWorkspaceLive ? "" : "AND ew.status = 'online'"}
     ORDER BY CASE WHEN i.owner_user_id = ?2 THEN 0 ELSE 1 END,
              active_assignments, ew.id, i.worker_id`,
    )
    .bind(
      request.spaceId,
      request.requesterUserId,
      now.toISOString(),
      request.threadId ?? "",
      request.workRequestId ?? "",
    )
    .all<Row>()
    .catch(() => ({ results: [] as Row[] }));

  const excluded = new Set(request.excludeIndependenceKeys ?? []);
  const rejected: Array<Record<string, unknown>> = [];
  const liveWorkspaceChecks = new Map<string, Promise<boolean>>();
  const bindingFor = (row: Row): Record<string, unknown> => {
    const snapshot = object(row.work_request_snapshot_json);
    const snapshotBindings =
      snapshot.resolvedBindings && typeof snapshot.resolvedBindings === "object"
        ? (snapshot.resolvedBindings as Record<string, unknown>)
        : {};
    const bindings = request.workRequestId ? snapshotBindings : {};
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
    const acceptedSnapshot = object(row.work_request_snapshot_json);
    const stepConfigs = acceptedSnapshot.stepExecutionConfigs as
      Record<string, unknown> | undefined;
    const turnConfig = request.workRequestId
      ? ((stepConfigs?.[request.role] ??
          acceptedSnapshot.turnExecutionConfig) as
          Record<string, unknown> | undefined)
      : undefined;
    if (stepConfigs && !stepConfigs[request.role]) {
      rejected.push({
        workspaceId,
        workerId,
        reason: "step_configuration_unavailable",
      });
      continue;
    }
    if (
      turnConfig &&
      (turnConfig.schemaVersion !== 1 ||
        turnConfig.workerId !== workerId ||
        turnConfig.profileId !== row.profile_definition_id ||
        turnConfig.profileReleaseVersion !==
          Number(row.profile_release_version))
    ) {
      rejected.push({
        workspaceId,
        workerId,
        reason: "turn_configuration_unavailable",
      });
      continue;
    }
    const hasBinding = Object.keys(binding).length > 0;
    const preferredWorkerIds = [
      ...(typeof binding.workerId === "string" ? [binding.workerId] : []),
    ];
    const capabilities = strings(row.capabilities_json).map((value) =>
      value.toLowerCase(),
    );
    const requiredCapabilities = request.capabilities.map((value) =>
      value.toLowerCase(),
    );
    const grantCapabilities = parsedGrantJson(
      row.allowed_worker_capabilities_json,
      validateWorkspaceGrantCapabilities,
    );
    const selectedModel = turnConfig
      ? typeof turnConfig.modelId === "string"
        ? turnConfig.modelId
        : null
      : request.threadId &&
          typeof binding.model === "string" &&
          binding.model.trim().length > 0
        ? binding.model
        : (request.model ??
          (typeof binding.model === "string" ? binding.model : undefined));
    const selectedReasoningEffort = turnConfig
      ? typeof turnConfig.effort === "string"
        ? turnConfig.effort
        : null
      : request.threadId &&
          typeof binding.reasoningEffort === "string" &&
          binding.reasoningEffort.trim().length > 0
        ? binding.reasoningEffort
        : (request.reasoningEffort ??
          (typeof binding.reasoningEffort === "string"
            ? binding.reasoningEffort
            : undefined));
    const independenceKey = workerTypeId;
    const grantWorkerIds = parsedGrantJson(
      row.allowed_worker_ids_json,
      validateWorkspaceGrantWorkerIds,
    );
    const grantPermissions = parsedGrantJson(
      row.allowed_permissions_json,
      validateWorkspaceGrantPermissions,
    );
    const networkPolicy = parsedGrantJson(
      row.network_policy_json,
      validateWorkspaceNetworkPolicy,
    );
    const concurrency = parsedGrantJson(
      row.concurrency_json,
      validateWorkspaceConcurrencyPolicy,
    );
    const grantPolicyValid =
      isWorkspaceSpaceGrantStatus(row.grant_status) &&
      row.grant_status === "active" &&
      grantWorkerIds !== null &&
      grantCapabilities !== null &&
      grantPermissions !== null &&
      networkPolicy !== null &&
      concurrency !== null;
    const maxConcurrent = grantPolicyValid
      ? Math.min(
          number(row.local_concurrency_limit, 0),
          row.cloud_concurrency_limit == null
            ? 1024
            : number(row.cloud_concurrency_limit, 0),
          concurrency.maxConcurrentAssignments,
        )
      : 0;

    const reject = (reason: string) =>
      rejected.push({ workspaceId, workerId, reason });
    const catalogReleaseStage = String(row.worker_catalog_release_stage);
    const workspaceProfileChannel = String(
      row.workspace_tool_profile_channel ?? "stable",
    );
    const catalogStageEligible =
      workspaceProfileChannel === "testing" ||
      (workspaceProfileChannel === "beta" &&
        ["beta", "stable"].includes(catalogReleaseStage)) ||
      (workspaceProfileChannel === "stable" &&
        catalogReleaseStage === "stable");
    if (
      row.worker_catalog_lifecycle_state !== "active" ||
      row.worker_catalog_visibility_state !== "visible" ||
      !catalogStageEligible
    ) {
      reject("worker_catalog_unavailable");
      continue;
    }
    if (
      typeof row.current_profile_definition_id !== "string" ||
      row.current_profile_definition_id !== row.profile_definition_id
    ) {
      reject("worker_profile_definition_unavailable");
      continue;
    }
    if (!grantPolicyValid) {
      reject("workspace_grant_policy_invalid");
      continue;
    }
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
    if (request.threadId && !hasBinding) {
      reject("thread_step_binding_missing");
      continue;
    }
    if (request.workspaceId && request.workspaceId !== workspaceId) {
      reject("explicit_workspace_mismatch");
      continue;
    }
    if (
      request.threadId &&
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
    if (grantWorkerIds.length > 0 && !grantWorkerIds.includes(workerId)) {
      reject("worker_not_allowed_by_grant");
      continue;
    }
    if (!allowedByJson(row, "allowed_worker_type_ids_json", workerTypeId)) {
      reject("worker_type_not_allowed_by_thread");
      continue;
    }
    const allowedModels = strings(row.allowed_models_json);
    if (
      allowedModels.length > 0 &&
      (!selectedModel || !allowedModels.includes(selectedModel))
    ) {
      reject("model_not_allowed_by_thread");
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

    const resolvedPermissions = resolveExecutionPermissions(
      rights.work ? [...EXECUTION_PERMISSIONS] : ["repository:read"],
      grantPermissions,
    );
    // Read-only steps may keep the active Thread lease so they inspect its
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
      spaceId: request.spaceId,
      workspaceId,
      workerId,
      workerTypeId,
      grantId: String(row.grant_id),
      workerDisplayName: String(row.worker_display_name ?? workerTypeId),
      engineVersion: String(row.engine_version),
      profileDefinitionId: String(row.profile_definition_id),
      profileReleaseVersion: Number(row.profile_release_version),
      model: selectedModel ?? null,
      reasoningEffort: selectedReasoningEffort ?? null,
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
      networkPolicy,
      concurrency,
      threadPolicy: {
        allowedWorkerTypeIds: strings(row.allowed_worker_type_ids_json),
        allowedModels,
      },
      snapshotAt,
    };
    return {
      spaceId: request.spaceId,
      workspaceId,
      workspaceRuntimeIdentityId: String(row.runtime_identity_id),
      workspaceSpaceGrantId: String(row.grant_id),
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
      reasoningEffort: selectedReasoningEffort ?? null,
      effectivePermissions: permissions,
      permissionSnapshot,
      selectionExplanation: {
        spaceMembership: membership.role,
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
          "space_authorized",
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
      ...(typeof row.conversation_id === "string"
        ? {
            conversationId: row.conversation_id,
            baseContextRevision: number(row.base_context_revision),
          }
        : {}),
      executionClass,
      readOnly:
        executionClass === "stateless_read" || request.readOnly === true,
      ...(statefulLease
        ? {
            threadId: statefulLease.threadId,
            workRequestId: statefulLease.workRequestId,
            leaseId: statefulLease.leaseId,
            fencingToken: statefulLease.fencingToken,
          }
        : {}),
    };
  }
  return null;
}
