import { loadSpacePermissions } from "./space-permissions.js";
import { spaceWorkerExecutionOptions } from "../worker-execution-options.js";
import { type Permission, type SecurityContext } from "@conclave/security";
import {
  validateWorkerExecutionSelection,
  canDiscussThread,
  canExecuteThread,
  canManageThread,
  canViewThread,
  DEFAULT_THREAD_ACCESS_POLICY,
  type SpaceMembership,
  type Thread,
  type BuiltinWorkflowDefinition,
  type WorkflowId,
  WORKFLOW_IDS,
  THREAD_BINDING_IDS,
  WORKER_INPUT_CAPABILITIES,
  validateWorkspaceGrantCapabilities,
  validateWorkspaceGrantPermissions,
  validateWorkspaceGrantWorkerIds,
} from "@conclave/core";

import type { SecurityEnv } from "./http-security.js";
import { authorizeRequest } from "./http-security.js";

import { HttpError, parseJson } from "./http-security.js";

/** Thread configuration owns authored context, never global execution choices. */
export function normalizeThreadWorkConfig(value: unknown): {
  config: Record<string, unknown>;
} {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new HttpError(400, "workConfig must be an object");
  const input = value as Record<string, unknown>;
  if (
    Object.keys(input).some(
      (key) =>
        !["defaultWorkflowId", "threadInstructions", "bindings"].includes(key),
    ) ||
    typeof input.defaultWorkflowId !== "string" ||
    !WORKFLOW_IDS.includes(input.defaultWorkflowId as WorkflowId) ||
    !input.bindings ||
    typeof input.bindings !== "object" ||
    Array.isArray(input.bindings)
  )
    throw new HttpError(400, "workConfig is invalid");
  const text = (value: unknown): string | undefined => {
    if (value === undefined) return undefined;
    if (typeof value !== "string" || value.length > 4000)
      throw new HttpError(400, "workConfig instructions are invalid");
    return value.trim() || undefined;
  };
  const threadInstructions = text(input.threadInstructions);
  const bindings: Record<string, { additionalInstructions: string }> = {};
  for (const [id, raw] of Object.entries(
    input.bindings as Record<string, unknown>,
  )) {
    if (
      !(THREAD_BINDING_IDS as readonly string[]).includes(id) ||
      !raw ||
      typeof raw !== "object" ||
      Array.isArray(raw)
    )
      throw new HttpError(400, "workConfig binding is invalid");
    const binding = raw as Record<string, unknown>;
    if (Object.keys(binding).some((key) => key !== "additionalInstructions"))
      throw new HttpError(
        400,
        "Thread execution preferences are not supported; use Workflows",
      );
    const instructions = text(binding.additionalInstructions);
    if (instructions) bindings[id] = { additionalInstructions: instructions };
  }
  return {
    config: {
      defaultWorkflowId: input.defaultWorkflowId,
      ...(threadInstructions ? { threadInstructions } : {}),
      bindings,
    },
  };
}

export function threadMetadata(
  row: Record<string, unknown>,
): Record<string, unknown> {
  const accessPolicy = parseJson<Record<string, unknown>>(
    row.accessPolicyJson ?? row.access_policy_json,
    {},
  );
  return {
    id: String(row.id),
    spaceId: String(row.spaceId ?? row.space_id),
    name: String(row.name),
    status: String(row.status),
    createdByUserId: row.leadUserId ?? row.lead_user_id ?? null,
    creatorEmail: row.creatorEmail ?? null,
    creatorIsOwner: row.creatorIsOwner === 1,
    lead: row.leadUserId ?? row.lead_user_id ?? null,
    accessPolicy,
    workConfig: parseJson(row.workConfigJson ?? row.configJson, {
      defaultWorkflowId: "full_cycle",
      bindings: {},
    }),
    primaryWorkspace:
      accessPolicy.primaryWorkspaceId ??
      accessPolicy.primary_workspace_id ??
      null,
    queueStatus: "Idle",
    createdAt: String(row.createdAt ?? row.created_at),
    updatedAt: String(row.updatedAt ?? row.updated_at),
  };
}

export function sortThreads<T extends Record<string, unknown>>(
  threads: T[],
  threadOrder?: unknown,
): T[] {
  const hasCustomOrder = Array.isArray(threadOrder) && threadOrder.length > 0;
  const orderMap = new Map<string, number>();
  if (hasCustomOrder) {
    (threadOrder as unknown[]).forEach((id, index) => {
      if (typeof id === "string") orderMap.set(id, index);
    });
  }
  return [...threads].sort((a, b) => {
    const aId = String(a.id ?? "");
    const bId = String(b.id ?? "");
    if (hasCustomOrder) {
      const aIndex = orderMap.has(aId) ? orderMap.get(aId)! : 999999;
      const bIndex = orderMap.has(bId) ? orderMap.get(bId)! : 999999;
      if (aIndex !== bIndex) {
        return aIndex - bIndex;
      }
    }
    const aCreated = String(a.createdAt ?? a.created_at ?? "");
    const bCreated = String(b.createdAt ?? b.created_at ?? "");
    return aCreated.localeCompare(bCreated);
  });
}

export function discussionReferences(value: unknown): readonly string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value))
    throw new HttpError(400, "references must be an array");
  return value.flatMap((reference) => {
    if (typeof reference === "string" && reference.trim())
      return [reference.trim()];
    if (reference && typeof reference === "object") {
      const id = (reference as Record<string, unknown>).id;
      if (typeof id === "string" && id.trim()) return [id.trim()];
    }
    throw new HttpError(400, "references must contain non-empty identifiers");
  });
}

export type ThreadAccess = "view" | "discuss" | "execute" | "manage";

export async function authorizeThreadAccess(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  access: ThreadAccess,
  accessContext?: ExecutionContext,
): Promise<{
  context: SecurityContext;
  thread: Thread;
  spaceId: string;
}> {
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT id, space_id AS spaceId, name, status,
            access_policy_json AS accessPolicyJson, lead_user_id AS leadUserId,
            created_at AS createdAt, updated_at AS updatedAt
     FROM threads WHERE id = ?1`,
  )
    .bind(threadId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Thread not found");

  const permission: Permission =
    access === "view"
      ? "spaces:read"
      : access === "discuss"
        ? "spaces:write"
        : access === "execute"
          ? "run.start"
          : "spaces:write";
  const context = await authorizeRequest(
    request,
    env,
    permission,
    String(row.spaceId),
    accessContext,
  );
  const membership = await env.CONCLAVE_DB.prepare(
    `SELECT id, space_id AS spaceId, user_id AS userId, role,
            created_at AS createdAt, updated_at AS updatedAt
     FROM space_memberships WHERE space_id = ?1 AND user_id = ?2`,
  )
    .bind(String(row.spaceId), context.userId)
    .first<SpaceMembership>();
  const policy = await loadSpacePermissions(
    env,
    context.userId,
    String(row.spaceId),
  );
  const effectiveMembership = membership
    ? { ...membership, permissions: policy.rights }
    : null;
  const thread: Thread = {
    id: String(row.id),
    spaceId: String(row.spaceId),
    name: String(row.name),
    status: String(row.status) as Thread["status"],
    accessPolicy: {
      ...DEFAULT_THREAD_ACCESS_POLICY,
      ...parseJson(row.accessPolicyJson, {}),
    },
    lead: {
      userId: String(row.leadUserId),
      assignedAt: String(row.createdAt),
      assignedByUserId: String(row.leadUserId),
    },
    createdAt: String(row.createdAt),
    updatedAt: String(row.updatedAt),
  };
  const allowed =
    access === "view"
      ? canViewThread(context.userId, effectiveMembership, thread)
      : access === "discuss"
        ? canDiscussThread(context.userId, effectiveMembership, thread)
        : access === "execute"
          ? canExecuteThread(context.userId, effectiveMembership, thread)
          : canManageThread(context.userId, effectiveMembership, thread);
  if (!allowed) throw new HttpError(403, `Thread ${access} access is required`);
  return { context, thread, spaceId: String(row.spaceId) };
}

export async function threadSpaceId(
  env: SecurityEnv,
  threadId: string,
): Promise<string> {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT space_id AS spaceId FROM threads WHERE id = ?1",
  )
    .bind(threadId)
    .first<{ spaceId: string }>();
  if (!row) throw new HttpError(404, "Thread not found");
  return row.spaceId;
}

export type WorkEligibilityIssue = {
  stepKind: string;
  workerTypeId: string | null;
  code: string;
  message: string;
};

export function eligibilityMessage(
  stepKind: string,
  workerTypeId: string | null,
  code: string,
  readinessIssueCode?: string | null,
  displayName?: string | null,
): string {
  const step = stepKind[0]?.toUpperCase() + stepKind.slice(1);
  const worker =
    displayName?.trim() || (workerTypeId ? "Selected Worker" : "Worker");
  if (code === "binding_missing") return `${step}: choose a Worker.`;
  if (code === "worker_missing")
    return `${step}: the selected Worker is no longer available.`;
  if (code === "space_workspace_grant_missing")
    return `${step}: grant this Space access to the Worker's Workspace.`;
  if (code === "worker_disabled") return `${step}: ${worker} is disabled.`;
  if (code === "worker_not_ready") {
    if (
      readinessIssueCode === "sign_in_required" ||
      readinessIssueCode === "provider_authentication_required"
    ) {
      return `${step}: ${worker} needs sign-in.`;
    }
    return `${step}: ${worker} is not Ready${readinessIssueCode ? ` (${readinessIssueCode.replaceAll("_", " ")})` : ""}.`;
  }
  if (code === "worker_catalog_unavailable")
    return `${step}: this Worker is no longer available in the Workspace catalog.`;
  if (code === "worker_scheduling_disabled")
    return `${step}: ${worker} is not enabled for scheduling.`;
  if (code === "capability_missing")
    return `${step}: ${worker} does not have the capability required by this Step.`;
  if (code === "capability_not_granted")
    return `${step}: the Space Workspace grant does not allow this Step's capability.`;
  if (code === "permission_not_granted")
    return `${step}: the Space Workspace grant does not allow the access this Step needs.`;
  if (code === "worker_not_allowed_by_grant")
    return `${step}: this Worker is not included in the Space Workspace grant.`;
  if (code === "worker_type_not_allowed_by_thread")
    return `${step}: this Worker type is not allowed by the Thread execution policy.`;
  if (code === "workspace_offline")
    return `${step}: the Worker's Workspace is offline.`;
  if (code === "workspace_mismatch")
    return `${step}: all Steps in this Workflow must use Workers from the same Workspace.`;
  if (code === "workspace_not_primary")
    return `${step}: the Worker must be on this Thread's primary Workspace.`;
  if (code === "engine_profile_unavailable")
    return `${step}: the Worker has no compatible Engine and Tool Profile release.`;
  if (code === "model_not_allowed")
    return `${step}: the selected model is not allowed by this Thread.`;
  if (code === "model_required")
    return `${step}: choose a model allowed by this Thread.`;
  if (code === "runtime_coordinator_unavailable")
    return "Thread execution coordination is unavailable. Try again later.";
  return `${step}: ${worker} is not eligible to run this Work.`;
}

export async function validateWorkflowWorkerEligibility(
  env: SecurityEnv,
  spaceId: string,
  threadId: string,
  workflow: BuiltinWorkflowDefinition,
  bindings: Record<
    string,
    { workerId?: string; model?: string; reasoningEffort?: string }
  >,
  attachments: readonly unknown[] = [],
): Promise<{
  issues: WorkEligibilityIssue[];
  primaryWorkspaceId: string | null;
  workerProfiles: Record<
    string,
    { profileId: string; profileReleaseVersion: number }
  >;
}> {
  const issues: WorkEligibilityIssue[] = [];
  const workerProfiles: Record<
    string,
    { profileId: string; profileReleaseVersion: number }
  > = {};
  let primaryWorkspaceId: string | null = null;
  const now = new Date().toISOString();
  for (const step of workflow.steps) {
    const bindingId = workflow.id === "direct" ? "direct" : step.kind;
    const binding = bindings[bindingId];
    if (!binding?.workerId) {
      issues.push({
        stepKind: step.kind,
        workerTypeId: null,
        code: "binding_missing",
        message: eligibilityMessage(step.kind, null, "binding_missing"),
      });
      continue;
    }
    const row = await env.CONCLAVE_DB.prepare(
      `SELECT i.workspace_id AS workspaceId, i.worker_type_id AS workerTypeId,
              i.activation_state AS activationState, i.readiness_state AS readinessState,
              i.readiness_issue_code AS readinessIssueCode, i.capabilities_json AS capabilitiesJson,
              i.engine_version AS engineVersion,
              i.profile_definition_id AS profileDefinitionId,
              i.profile_release_version AS profileReleaseVersion,
              i.provider_tool_version AS providerToolVersion,
              release.payload_json AS executionProfileJson,
              catalog.lifecycle_state AS workerCatalogLifecycleState,
              catalog.visibility_state AS workerCatalogVisibilityState,
              catalog.release_stage AS workerCatalogReleaseStage,
              profileChannel.channel AS workspaceToolProfileChannel,
              definition.profile_definition_id AS currentProfileDefinitionId,
              catalog.display_name AS workerDisplayName,
              vs.state AS schedulingState,
              g.id AS grantId, g.status AS grantStatus, g.expires_at AS grantExpiresAt,
              g.allowed_worker_ids_json AS allowedWorkerIdsJson,
              g.allowed_worker_capabilities_json AS grantCapabilitiesJson,
              g.allowed_permissions_json AS grantPermissionsJson,
              ep.allowed_models_json AS allowedModelsJson,
              ep.primary_workspace_id AS primaryWorkspaceId,
              ep.allowed_worker_type_ids_json AS allowedThreadWorkerTypesJson,
              ew.status AS workspaceStatus,
              wri.id AS runtimeIdentityId
         FROM workspace_worker_inventory i
         LEFT JOIN worker_catalog catalog
           ON catalog.worker_type_id = i.worker_type_id
         LEFT JOIN workspace_tool_profile_channels profileChannel
           ON profileChannel.workspace_id = i.workspace_id
         LEFT JOIN tool_profile_definitions definition
           ON definition.worker_type_id = i.worker_type_id
          AND definition.profile_definition_id = i.profile_definition_id
          AND definition.lifecycle_state = 'active'
         LEFT JOIN tool_profile_releases release
           ON release.profile_definition_id = i.profile_definition_id
          AND release.release_version = i.profile_release_version
          AND release.worker_type_id = i.worker_type_id
          AND release.published_at IS NOT NULL
          AND release.lifecycle_state <> 'revoked'
         LEFT JOIN worker_scheduling vs ON vs.worker_id = i.worker_id
         LEFT JOIN workspace_space_grants g
           ON g.workspace_id = i.workspace_id AND g.space_id = ?2
         LEFT JOIN thread_execution_policies ep ON ep.thread_id = ?3
         LEFT JOIN execution_workspaces ew ON ew.id = i.workspace_id
         LEFT JOIN workspace_runtime_identities wri ON wri.workspace_id = i.workspace_id AND wri.revoked_at IS NULL
        WHERE i.worker_id = ?1`,
    )
      .bind(binding.workerId, spaceId, threadId)
      .first<Record<string, unknown>>();
    if (!row) {
      const code = "worker_missing";
      issues.push({
        stepKind: step.kind,
        workerTypeId: null,
        code,
        message: eligibilityMessage(step.kind, null, code),
      });
      continue;
    }
    const workerTypeId = String(row.workerTypeId);
    const push = (code: string) =>
      issues.push({
        stepKind: step.kind,
        workerTypeId,
        code,
        message: eligibilityMessage(
          step.kind,
          workerTypeId,
          code,
          row.readinessIssueCode == null
            ? null
            : String(row.readinessIssueCode),
          row.workerDisplayName == null ? null : String(row.workerDisplayName),
        ),
      });
    const catalogReleaseStage = String(row.workerCatalogReleaseStage ?? "");
    const workspaceToolProfileChannel = String(
      row.workspaceToolProfileChannel ?? "stable",
    );
    const catalogStageEligible =
      workspaceToolProfileChannel === "testing" ||
      (workspaceToolProfileChannel === "beta" &&
        ["beta", "stable"].includes(catalogReleaseStage)) ||
      (workspaceToolProfileChannel === "stable" &&
        catalogReleaseStage === "stable");
    if (
      row.workerCatalogLifecycleState !== "active" ||
      row.workerCatalogVisibilityState !== "visible" ||
      !catalogStageEligible
    ) {
      push("worker_catalog_unavailable");
    }
    if (
      typeof row.currentProfileDefinitionId !== "string" ||
      row.currentProfileDefinitionId !== row.profileDefinitionId
    ) {
      push("engine_profile_unavailable");
    }
    if (
      row.grantId == null ||
      row.grantStatus !== "active" ||
      (row.grantExpiresAt != null && String(row.grantExpiresAt) <= now)
    )
      push("space_workspace_grant_missing");
    if (row.activationState !== "enabled") push("worker_disabled");
    if (row.readinessState !== "ready") push("worker_not_ready");
    if (row.schedulingState !== "enabled") push("worker_scheduling_disabled");
    if (
      typeof row.engineVersion !== "string" ||
      !row.engineVersion ||
      typeof row.profileDefinitionId !== "string" ||
      !row.profileDefinitionId ||
      !Number.isSafeInteger(Number(row.profileReleaseVersion)) ||
      Number(row.profileReleaseVersion) < 1
    )
      push("engine_profile_unavailable");
    if (row.workspaceStatus !== "online") push("workspace_offline");
    if (row.runtimeIdentityId == null) push("workspace_offline");
    const capabilities = parseJson<unknown[]>(row.capabilitiesJson, []).filter(
      (value): value is string => typeof value === "string",
    );
    const requiredCapabilities = [...step.requiredCapabilities];
    if (
      !requiredCapabilities.every((capability) =>
        capabilities.includes(capability),
      )
    )
      push("capability_missing");
    const rawGrantCapabilities = parseJson<unknown>(
      row.grantCapabilitiesJson,
      null,
    );
    if (!validateWorkspaceGrantCapabilities(rawGrantCapabilities)) {
      push("workspace_grant_policy_invalid");
    }
    const grantCapabilities = validateWorkspaceGrantCapabilities(
      rawGrantCapabilities,
    )
      ? rawGrantCapabilities
      : [];
    if (
      grantCapabilities.length > 0 &&
      !requiredCapabilities.every((capability) =>
        grantCapabilities.includes(capability),
      )
    )
      push("capability_not_granted");
    const receivesAttachments =
      step.kind === "research" || step.kind === "implement";
    const requiredInputCapabilities = [
      "text",
      ...(receivesAttachments
        ? attachmentRequiredCapabilities(attachments)
        : []),
    ];
    const availableInputCapabilities = capabilities.filter((capability) =>
      (WORKER_INPUT_CAPABILITIES as readonly string[]).includes(capability),
    );
    for (const capability of requiredInputCapabilities) {
      if (!availableInputCapabilities.includes(capability)) {
        issues.push({
          stepKind: step.kind,
          workerTypeId,
          code: "input_capability_missing",
          message: inputCapabilityMessage(
            step.kind,
            workerTypeId,
            capability,
            false,
            row.workerDisplayName == null
              ? null
              : String(row.workerDisplayName),
          ),
        });
      }
      if (
        grantCapabilities.length > 0 &&
        !grantCapabilities.includes(capability)
      ) {
        issues.push({
          stepKind: step.kind,
          workerTypeId,
          code: "input_capability_not_granted",
          message: inputCapabilityMessage(
            step.kind,
            workerTypeId,
            capability,
            true,
            row.workerDisplayName == null
              ? null
              : String(row.workerDisplayName),
          ),
        });
      }
    }
    const rawGrantPermissions = parseJson<unknown>(
      row.grantPermissionsJson,
      null,
    );
    if (!validateWorkspaceGrantPermissions(rawGrantPermissions)) {
      push("workspace_grant_policy_invalid");
    }
    const grantPermissions = validateWorkspaceGrantPermissions(
      rawGrantPermissions,
    )
      ? rawGrantPermissions
      : [];
    const requiredPermissions = new Set<string>(["repository:read"]);
    if (step.requiredCapabilities.includes("thread_write"))
      requiredPermissions.add("repository:write");
    if (step.requiredCapabilities.includes("test_execution"))
      requiredPermissions.add("shell:execute");
    const grantPermissionSet = new Set<string>(grantPermissions);
    if (
      ![...requiredPermissions].every((permission) =>
        grantPermissionSet.has(permission),
      )
    )
      push("permission_not_granted");
    const rawAllowedWorkerIds = parseJson<unknown>(
      row.allowedWorkerIdsJson,
      null,
    );
    if (!validateWorkspaceGrantWorkerIds(rawAllowedWorkerIds)) {
      push("workspace_grant_policy_invalid");
    }
    const allowedWorkerIds = validateWorkspaceGrantWorkerIds(
      rawAllowedWorkerIds,
    )
      ? rawAllowedWorkerIds
      : [];
    if (
      allowedWorkerIds.length > 0 &&
      !allowedWorkerIds.includes(binding.workerId)
    )
      push("worker_not_allowed_by_grant");
    const allowedThreadTypes = parseJson<unknown[]>(
      row.allowedThreadWorkerTypesJson,
      [],
    ).filter((value): value is string => typeof value === "string");
    if (
      allowedThreadTypes.length > 0 &&
      !allowedThreadTypes.includes(workerTypeId)
    )
      push("worker_type_not_allowed_by_thread");
    const executionOptions = spaceWorkerExecutionOptions(
      row.executionProfileJson,
      row.providerToolVersion,
    );
    if (executionOptions) {
      const error = validateWorkerExecutionSelection(
        executionOptions,
        binding.model ?? null,
        binding.reasoningEffort ?? null,
      );
      if (error)
        issues.push({
          stepKind: step.kind,
          workerTypeId,
          code: "profile_execution_option_unavailable",
          message: `${step.kind}: ${error}.`,
        });
    }
    const allowedModels = parseJson<unknown[]>(
      row.allowedModelsJson,
      [],
    ).filter((value): value is string => typeof value === "string");
    if (allowedModels.length > 0 && !binding.model?.trim())
      push("model_required");
    else if (
      binding.model?.trim() &&
      allowedModels.length > 0 &&
      !allowedModels.includes(binding.model)
    )
      push("model_not_allowed");
    if (
      typeof row.profileDefinitionId === "string" &&
      Number.isSafeInteger(Number(row.profileReleaseVersion))
    ) {
      workerProfiles[bindingId] = {
        profileId: row.profileDefinitionId,
        profileReleaseVersion: Number(row.profileReleaseVersion),
      };
    }
    if (primaryWorkspaceId == null)
      primaryWorkspaceId = String(row.workspaceId);
    else if (primaryWorkspaceId !== String(row.workspaceId))
      push("workspace_mismatch");
    if (
      row.primaryWorkspaceId != null &&
      String(row.primaryWorkspaceId) !== String(row.workspaceId)
    )
      push("workspace_not_primary");
  }
  return { issues, primaryWorkspaceId, workerProfiles };
}

export function attachmentRequiredCapabilities(
  attachments: readonly unknown[],
): string[] {
  const required = new Set<string>();
  for (const value of attachments) {
    if (!value || typeof value !== "object" || Array.isArray(value)) continue;
    const attachment = value as Record<string, unknown>;
    if (attachment.kind !== "file") continue;
    required.add("local_file");
    const mediaType =
      typeof attachment.mediaType === "string"
        ? attachment.mediaType.toLowerCase()
        : "";
    if (mediaType.startsWith("text/")) required.add("text");
    else if (mediaType.startsWith("image/")) required.add("image");
    else if (mediaType.startsWith("audio/")) required.add("audio");
    else if (mediaType.startsWith("video/")) required.add("video");
  }
  return [...required];
}

export function inputCapabilityMessage(
  stepKind: string,
  workerTypeId: string,
  capability: string,
  grantDenied = false,
  displayName?: string | null,
): string {
  const step = stepKind[0]?.toUpperCase() + stepKind.slice(1);
  const worker =
    displayName?.trim() || (workerTypeId ? "Selected Worker" : "Worker");
  const input = capability === "local_file" ? "local file" : capability;
  return grantDenied
    ? `${step} ${worker} is not granted ${input} input by the Space Workspace grant.`
    : `${step} ${worker} does not support ${input} input.`;
}

export function summarizeTestCounts(text: string): string | null {
  const counts: string[] = [];
  for (const status of ["failed", "passed", "skipped"] as const) {
    const matches = text.matchAll(
      new RegExp(`\\b(\\d+)\\s+(?:tests?\\s+)?${status}\\b`, "gi"),
    );
    const match = [...matches].at(-1);
    if (match) counts.push(`${match[1]} ${status}`);
  }
  return counts.length > 0 ? counts.join(", ") : null;
}
