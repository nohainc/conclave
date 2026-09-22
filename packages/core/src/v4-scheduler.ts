import {
  canUseCredentialProfile,
  type CredentialGrant,
  type CredentialProfile,
  type CredentialWorkspaceRole,
  type V4WorkerAssignment,
} from "./v4-entities.js";

export type ExecutionPreference = "auto" | "subscription" | "api";

export interface ProjectExecutionPreferences {
  readonly preferredWorkerIds?: readonly string[];
  readonly preferredModels?: readonly string[];
  readonly preferredCredentialProfileIds?: readonly string[];
  readonly quality?: "fast" | "balanced" | "high";
  readonly maxCostMicros?: number | null;
}

export interface UserExecutionPreferences {
  readonly preferredPrivateCredentialProfileId?: string | null;
  readonly executionPreference?: ExecutionPreference;
}

export interface V4TaskRequirements {
  readonly role?: string;
  readonly capabilities?: readonly string[];
  readonly model?: string | null;
  readonly explicitWorkerId?: string | null;
  readonly explicitCredentialProfileId?: string | null;
  readonly requesterUserId: string;
  readonly workspaceRole?: CredentialWorkspaceRole;
  readonly excludeIndependenceKeys?: readonly string[];
  readonly budgetRemainingMicros?: number | null;
}

export interface AvailableWorkerAccount {
  readonly workerId: string;
  readonly hostId: string;
  readonly workerVersion: string;
  readonly capabilities: readonly string[];
  readonly roles: readonly string[];
  readonly model?: string | null;
  readonly billingMode: "subscription" | "api" | "local";
  readonly activeAssignments: number;
  readonly concurrencyLimit: number;
  readonly credentialProfile: CredentialProfile;
  readonly grants: readonly CredentialGrant[];
  readonly credentialUsageCount?: number;
  readonly supportedModels?: readonly string[];
  readonly hostStatus?: "online" | "offline" | "draining" | "revoked";
  readonly installationStatus?:
    "installing" | "installed" | "active" | "error" | "removed";
  readonly independenceKey?: string;
  readonly estimatedCostMicros?: number;
}

export interface ResolvedWorkerTarget {
  readonly status: "ready";
  readonly workerId: string;
  readonly hostId: string;
  readonly workerVersion: string;
  readonly credentialProfileId: string;
  readonly model: string | null;
  readonly reason: "auto" | "explicit" | "preferred";
}

export interface SetupRequiredExecutionTarget {
  readonly status: "setup_required";
  readonly workerId: string | null;
  readonly reason: "missing_credential" | "no_eligible_worker";
}

export type ExecutionResolution =
  ResolvedWorkerTarget | SetupRequiredExecutionTarget;

export interface AssignmentSnapshotInput {
  readonly assignmentId: string;
  readonly workspaceId: string;
  readonly projectId: string;
  readonly runId: string;
  readonly taskId: string;
  readonly attemptId: string;
  readonly requestedByUserId: string;
  readonly target: ResolvedWorkerTarget;
  readonly model?: string | null;
  readonly config?: Record<string, unknown>;
  readonly sessionPolicy?: V4WorkerAssignment["sessionPolicy"];
  readonly permissions?: readonly string[];
  readonly contextRefs?: readonly Record<string, unknown>[];
  readonly timeoutMs: number;
  readonly idempotencyKey: string;
  readonly input?: Record<string, unknown>;
  readonly now: string;
}

/** Freezes the resolver result into the immutable v4 assignment snapshot. */
export function createAssignmentSnapshot(
  input: AssignmentSnapshotInput,
): V4WorkerAssignment {
  return {
    id: input.assignmentId,
    workspaceId: input.workspaceId,
    projectId: input.projectId,
    runId: input.runId,
    taskId: input.taskId,
    attemptId: input.attemptId,
    requestedByUserId: input.requestedByUserId,
    hostId: input.target.hostId,
    workerId: input.target.workerId,
    credentialProfileId: input.target.credentialProfileId,
    resolvedWorkerVersion: input.target.workerVersion,
    model: input.model ?? input.target.model ?? undefined,
    assignmentConfig: { ...(input.config ?? {}) },
    sessionPolicy: input.sessionPolicy ?? "stateless",
    permissions: [...(input.permissions ?? [])],
    contextRefs: [...(input.contextRefs ?? [])],
    status: "created",
    input: { ...(input.input ?? {}) },
    idempotencyKey: input.idempotencyKey,
    timeoutMs: input.timeoutMs,
    createdAt: input.now,
    updatedAt: input.now,
  };
}

/** Resolves a fresh Host + Worker + account target for one task. */
export function resolveExecutionTarget(
  task: V4TaskRequirements,
  available: readonly AvailableWorkerAccount[],
  project: ProjectExecutionPreferences = {},
  user: UserExecutionPreferences = {},
): ExecutionResolution {
  const explicit =
    task.explicitWorkerId != null || task.explicitCredentialProfileId != null;
  const requiredCapabilities = new Set(
    (task.capabilities ?? []).map((capability) => capability.toLowerCase()),
  );
  const requiredRole = task.role?.toLowerCase();
  const requested = available.filter((candidate) => {
    if (task.explicitWorkerId && candidate.workerId !== task.explicitWorkerId)
      return false;
    if (
      task.explicitCredentialProfileId &&
      candidate.credentialProfile.id !== task.explicitCredentialProfileId
    )
      return false;
    if (candidate.activeAssignments >= candidate.concurrencyLimit) return false;
    if (candidate.hostStatus && candidate.hostStatus !== "online") return false;
    if (
      candidate.installationStatus &&
      candidate.installationStatus !== "active"
    )
      return false;
    if (
      candidate.independenceKey &&
      task.excludeIndependenceKeys?.includes(candidate.independenceKey)
    )
      return false;
    if (
      requiredRole &&
      !candidate.roles.map((role) => role.toLowerCase()).includes(requiredRole)
    )
      return false;
    if (
      !Array.from(requiredCapabilities).every((capability) =>
        candidate.capabilities
          .map((value) => value.toLowerCase())
          .includes(capability),
      )
    )
      return false;
    if (task.model && candidate.model && candidate.model !== task.model)
      return false;
    if (
      task.model &&
      candidate.supportedModels &&
      !candidate.supportedModels.includes(task.model)
    )
      return false;
    if (
      user.executionPreference &&
      user.executionPreference !== "auto" &&
      candidate.billingMode !== user.executionPreference
    )
      return false;
    if (project.maxCostMicros != null && candidate.billingMode === "api")
      return false;
    if (
      task.budgetRemainingMicros != null &&
      candidate.estimatedCostMicros != null &&
      candidate.estimatedCostMicros > task.budgetRemainingMicros
    )
      return false;
    return canUseCredentialProfile(
      candidate.credentialProfile,
      candidate.grants,
      {
        workspaceId: candidate.credentialProfile.workspaceId,
        requesterUserId: task.requesterUserId,
        workspaceRole: task.workspaceRole,
        usageCount: candidate.credentialUsageCount,
      },
    );
  });

  if (requested.length === 0) {
    const workerMatch = available.some((candidate) =>
      task.explicitWorkerId
        ? candidate.workerId === task.explicitWorkerId
        : true,
    );
    return {
      status: "setup_required",
      workerId: task.explicitWorkerId ?? (workerMatch ? null : null),
      reason: workerMatch ? "missing_credential" : "no_eligible_worker",
    };
  }

  const workerRank = (workerId: string) => {
    const index = project.preferredWorkerIds?.indexOf(workerId) ?? -1;
    return index < 0 ? Number.MAX_SAFE_INTEGER : index;
  };
  const profileRank = (profileId: string) => {
    if (user.preferredPrivateCredentialProfileId === profileId) return -2;
    const index =
      project.preferredCredentialProfileIds?.indexOf(profileId) ?? -1;
    return index < 0 ? Number.MAX_SAFE_INTEGER : index;
  };
  const preferenceRank = (candidate: AvailableWorkerAccount) =>
    user.executionPreference === candidate.billingMode ? -1 : 0;
  const selected = [...requested].sort(
    (left, right) =>
      workerRank(left.workerId) - workerRank(right.workerId) ||
      profileRank(left.credentialProfile.id) -
        profileRank(right.credentialProfile.id) ||
      preferenceRank(left) - preferenceRank(right) ||
      left.activeAssignments - right.activeAssignments,
  )[0];
  if (!selected) {
    return {
      status: "setup_required",
      workerId: task.explicitWorkerId ?? null,
      reason: "no_eligible_worker",
    };
  }

  return {
    status: "ready",
    workerId: selected.workerId,
    hostId: selected.hostId,
    workerVersion: selected.workerVersion,
    credentialProfileId: selected.credentialProfile.id,
    model: task.model ?? selected.model ?? project.preferredModels?.[0] ?? null,
    reason: explicit
      ? "explicit"
      : project.preferredWorkerIds?.includes(selected.workerId)
        ? "preferred"
        : "auto",
  };
}
