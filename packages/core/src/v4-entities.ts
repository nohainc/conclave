/**
 * Conclave AX v4 Core domain entities.
 *
 * v4 execution model:
 *   Studio → Cloud → Host → Worker
 *
 * Core invariant:
 *   Cloud orchestrates. Hosts provide machines. Workers provide AI/tool
 *   capabilities. Credential Profiles provide identity and payment context.
 *
 * These types coexist with the v3 entities during migration. Later phases
 * (V4-5+) will migrate consumers and remove the v3 types.
 */

import { DomainInvariantError } from "./entities.js";

// Re-export so consumers can import everything from one module.
export { DomainInvariantError };

// ── Platform types (shared with v3, re-exported for convenience) ──────────

export type HostPlatform = "macos" | "linux" | "windows";
export type HostArchitecture = "arm64" | "x64";

// ── Host ──────────────────────────────────────────────────────────────────

export type HostStatus =
  "enrolled" | "online" | "offline" | "draining" | "revoked";

export interface HostCapabilities {
  readonly os: HostPlatform;
  readonly arch: HostArchitecture;
  readonly version: string;
  readonly supportedRuntimes: readonly string[];
  readonly maxConcurrentWorkers: number;
  readonly customCapabilities?: readonly string[];
}

/**
 * Host = one machine installation.
 *
 * A Host is NOT workspace-scoped. One Host can serve multiple Workspaces
 * through HostWorkspaceBinding. Host identity is independent from human
 * User identity.
 */
export interface Host {
  readonly id: string;
  readonly name: string;
  readonly hostname: string;
  readonly status: HostStatus;
  readonly version: string;
  readonly capabilities: HostCapabilities;
  readonly enrolledAt: string;
  readonly lastHeartbeatAt: string | null;
  readonly revokedAt: string | null;
}

// ── HostWorkspaceBinding ──────────────────────────────────────────────────

export type HostWorkspaceBindingStatus = "active" | "suspended" | "removed";

/**
 * Relates one Host to one Workspace. A Host may bind to many Workspaces.
 */
export interface HostWorkspaceBinding {
  readonly id: string;
  readonly hostId: string;
  readonly workspaceId: string;
  readonly status: HostWorkspaceBindingStatus;
  readonly createdAt: string;
  readonly updatedAt: string;
}

// ── HostEnrollment ────────────────────────────────────────────────────────

/**
 * One-time pairing token used to enroll a Host with Cloud.
 */
export interface HostEnrollment {
  readonly id: string;
  readonly workspaceId: string;
  readonly tokenHash: string;
  readonly expiresAt: string;
  readonly usedAt: string | null;
  readonly revokedAt: string | null;
  readonly createdBy: string;
}

// ── HostSession ───────────────────────────────────────────────────────────

/**
 * A live connection from a Host to Cloud.
 */
export interface HostSession {
  readonly id: string;
  readonly hostId: string;
  readonly connectedAt: string;
  readonly lastHeartbeatAt: string;
  readonly disconnectedAt: string | null;
  readonly clientVersion: string;
  readonly protocolVersion: string;
  readonly ipAddress?: string;
}

// ── HostRelease ───────────────────────────────────────────────────────────

export type HostReleaseChannel = "stable" | "beta" | "development";

/**
 * A versioned Host software package available for download.
 */
export interface HostRelease {
  readonly version: string;
  readonly channel: HostReleaseChannel;
  readonly minSupportedHostVersion?: string | null;
  readonly supportedOS: readonly HostPlatform[];
  readonly supportedArch: readonly HostArchitecture[];
  readonly packageDigest: string;
  readonly packageR2Key: string;
  readonly signature: string;
  readonly releaseNotes?: string | null;
  readonly isRevoked: boolean;
  readonly revokedAt?: string | null;
  readonly revocationReason?: string | null;
  readonly createdAt: string;
}

// ── V4Worker ──────────────────────────────────────────────────────────────

export type V4WorkerStatus = "active" | "deprecated" | "revoked";

/**
 * Worker = installable AI/tool integration (catalog entry).
 *
 * Examples: Codex, Claude Code, OpenAI, Anthropic, Ollama.
 *
 * Named V4Worker to avoid collision with the v3 configured-Worker-instance
 * entity during migration. After v3 deletion, this becomes simply Worker.
 */
export interface V4Worker {
  readonly id: string;
  readonly displayName: string;
  readonly description: string;
  readonly publisher: string;
  readonly supportedRoles: readonly string[];
  readonly supportedCapabilities: readonly string[];
  readonly status: V4WorkerStatus;
}

// ── V4WorkerVersion ───────────────────────────────────────────────────────

export type V4WorkerVersionChannel = "stable" | "beta" | "development";

export type V4WorkerBillingMode =
  | "api_metered"
  | "subscription"
  | "local_compute"
  | "external"
  | "manual"
  | "free";

/**
 * A versioned, signed Worker package.
 */
export interface V4WorkerVersion {
  readonly id: string;
  readonly workerId: string;
  readonly version: string;
  readonly channel: V4WorkerVersionChannel;
  readonly protocolVersion: string;
  readonly minHostVersion: string;
  readonly maxHostVersion?: string;
  readonly supportedOs: readonly HostPlatform[];
  readonly supportedArch: readonly HostArchitecture[];
  readonly packageDigest: string;
  readonly packageR2Key: string;
  readonly signature: string;
  readonly permissions: readonly string[];
  readonly billingModes: readonly V4WorkerBillingMode[];
  readonly configSchema?: Record<string, unknown>;
  readonly secretSchema?: Record<string, unknown>;
  readonly isRevoked: boolean;
  readonly revokedAt?: string | null;
  readonly revocationReason?: string | null;
  readonly createdAt: string;
}

// ── HostWorkerInstallation ────────────────────────────────────────────────

export type HostWorkerInstallationStatus =
  | "absent"
  | "requested"
  | "downloading"
  | "verifying"
  | "installing"
  | "ready"
  | "updating"
  | "degraded"
  | "failed"
  | "removing";

/**
 * One Worker version installed on one Host.
 */
export interface HostWorkerInstallation {
  readonly id: string;
  readonly hostId: string;
  readonly workerId: string;
  readonly workerVersionId: string;
  readonly resolvedVersion: string;
  readonly status: HostWorkerInstallationStatus;
  readonly installedAt: string | null;
  readonly updatedAt: string;
}

// ── CredentialProfile ─────────────────────────────────────────────────────

export type CredentialProfileOwnerType = "user" | "workspace";
export type CredentialProfileVisibility = "private" | "workspace";
export type CredentialProfileAuthType =
  "oauth" | "api_key" | "session_token" | "local" | "none";

/**
 * Credential Profile = whose account / API key / subscription is used.
 *
 * Private by default. Sharing requires an explicit CredentialGrant.
 * Workspace-owned profiles are workspace-visible by default.
 */
export interface CredentialProfile {
  readonly id: string;
  readonly ownerType: CredentialProfileOwnerType;
  readonly ownerId: string;
  readonly workspaceId: string;
  readonly workerId: string;
  readonly displayName: string;
  readonly authType: CredentialProfileAuthType;
  readonly visibility: CredentialProfileVisibility;
  readonly hostScope?: string | null;
  readonly createdAt: string;
  readonly updatedAt: string;
}

// ── CredentialGrant ───────────────────────────────────────────────────────

export type CredentialGranteeType = "user" | "workspace" | "role";

/**
 * Explicit sharing of a CredentialProfile.
 * Allows use, never secret disclosure.
 */
export interface CredentialGrant {
  readonly id: string;
  readonly credentialProfileId: string;
  readonly granteeType: CredentialGranteeType;
  readonly granteeId: string;
  /** The only supported permission is use; secret-read is never modeled. */
  readonly usePermission: "use";
  readonly grantedBy: string;
  readonly createdAt: string;
  readonly expiresAt?: string | null;
  readonly usageLimit?: number | null;
  readonly revokedAt?: string | null;
}

export type CredentialWorkspaceRole = "owner" | "admin" | "member" | "viewer";

export interface CredentialUseContext {
  readonly workspaceId: string;
  readonly requesterUserId: string;
  readonly workspaceRole?: CredentialWorkspaceRole;
  readonly now?: string;
  readonly usageCount?: number;
}

/**
 * Resolves use permission without ever exposing a profile secret.
 * Owners can use their own profile; all other access requires a live grant.
 */
export function canUseCredentialProfile(
  profile: CredentialProfile,
  grants: readonly CredentialGrant[],
  context: CredentialUseContext,
): boolean {
  if (profile.workspaceId !== context.workspaceId) return false;
  if (
    profile.ownerType === "user" &&
    profile.ownerId === context.requesterUserId
  ) {
    return true;
  }
  const role = context.workspaceRole;
  if (
    profile.ownerType === "workspace" &&
    role !== undefined &&
    role !== "viewer"
  ) {
    return true;
  }
  if (profile.visibility === "private") return false;
  const now = Date.parse(context.now ?? new Date().toISOString());
  return grants.some((grant) => {
    if (
      grant.credentialProfileId !== profile.id ||
      grant.usePermission !== "use" ||
      (grant.revokedAt !== null && grant.revokedAt !== undefined)
    ) {
      return false;
    }
    if (grant.expiresAt && Date.parse(grant.expiresAt) <= now) return false;
    if (
      grant.usageLimit !== null &&
      grant.usageLimit !== undefined &&
      (context.usageCount ?? 0) >= grant.usageLimit
    ) {
      return false;
    }
    return (
      (grant.granteeType === "user" &&
        grant.granteeId === context.requesterUserId) ||
      (grant.granteeType === "workspace" &&
        context.workspaceId === grant.granteeId &&
        role !== "viewer") ||
      (grant.granteeType === "role" && grant.granteeId === role)
    );
  });
}

// ── ResolvedExecutionTarget ───────────────────────────────────────────────

/**
 * Ephemeral snapshot resolving Host + Worker + Credential Profile for one
 * assignment. Created at dispatch time.
 *
 * This is NOT persisted as a long-lived entity. Its fields are embedded
 * directly into V4WorkerAssignment for immutable historical evidence.
 */
export interface V4ResolvedExecutionTarget {
  readonly hostId: string;
  readonly workerId: string;
  readonly credentialProfileId: string;
  readonly resolvedWorkerVersion: string;
  readonly model?: string;
  readonly config: Record<string, unknown>;
}

// ── V4WorkerAssignment ────────────────────────────────────────────────────

export type V4WorkerAssignmentStatus =
  | "created"
  | "dispatched"
  | "acknowledged"
  | "running"
  | "completed"
  | "failed"
  | "cancelled"
  | "timed_out";

/**
 * v4 Worker Assignment — execution using the Host + Worker + CredentialProfile
 * model. No legacy execution target fields.
 *
 * Snapshot fields (hostId, workerId, credentialProfileId, resolvedWorkerVersion,
 * model, assignmentConfig) are immutable: changing an account/model/Worker later
 * never rewrites historical evidence.
 */
export interface V4WorkerAssignment {
  readonly id: string;
  readonly workspaceId: string;
  readonly projectId: string;
  readonly runId: string;
  readonly taskId: string;
  readonly attemptId: string;
  readonly requestedByUserId: string;

  // v4 execution target snapshot
  readonly hostId: string;
  readonly workerId: string;
  readonly credentialProfileId: string;
  readonly resolvedWorkerVersion: string;
  readonly model?: string;
  readonly assignmentConfig: Record<string, unknown>;
  readonly sessionPolicy:
    "stateless" | "isolated_workspace" | "reuse_session" | "persistent_context";
  readonly permissions: readonly string[];
  readonly contextRefs: readonly Record<string, unknown>[];

  readonly status: V4WorkerAssignmentStatus;
  readonly input: Record<string, unknown>;
  readonly idempotencyKey: string;
  readonly timeoutMs: number;
  readonly createdAt: string;
  readonly updatedAt: string;
}

// ── V4WorkerAssignmentResult ──────────────────────────────────────────────

export type V4AssignmentTerminalStatus = "completed" | "failed" | "cancelled";

export interface V4AssignmentError {
  readonly code: string;
  readonly message: string;
  readonly retryable: boolean;
  readonly details?: Record<string, unknown>;
}

/**
 * Result from a v4 assignment execution.
 */
export interface V4WorkerAssignmentResult {
  readonly assignmentId: string;
  readonly workspaceId: string;
  readonly runId: string;
  readonly taskId: string;
  readonly attemptId: string;

  // v4 execution identity
  readonly hostId: string;
  readonly workerId: string;

  readonly status: V4AssignmentTerminalStatus;
  readonly output: Record<string, unknown> | null;
  readonly findings?: readonly unknown[];
  readonly artifactIds?: readonly string[];
  readonly error?: V4AssignmentError;
  readonly evidence?: {
    readonly observedAt: string;
    readonly metrics?: Record<string, unknown>;
    readonly logs?: readonly string[];
  };
  readonly completedAt: string;
}

// ── Validators ────────────────────────────────────────────────────────────

function requireNonEmpty(value: string | undefined | null, field: string) {
  if (!value || value.trim().length === 0) {
    throw new DomainInvariantError(`${field} is required`);
  }
}

const VALID_HOST_STATUSES: readonly string[] = [
  "enrolled",
  "online",
  "offline",
  "draining",
  "revoked",
];

const VALID_RELEASE_CHANNELS: readonly string[] = [
  "stable",
  "beta",
  "development",
];

const VALID_WORKER_STATUSES: readonly string[] = [
  "active",
  "deprecated",
  "revoked",
];

const VALID_INSTALLATION_STATUSES: readonly string[] = [
  "absent",
  "requested",
  "downloading",
  "verifying",
  "installing",
  "ready",
  "updating",
  "degraded",
  "failed",
  "removing",
];

/**
 * Validates invariants for a Host.
 */
export function validateHost(host: Host): void {
  requireNonEmpty(host.id, "Host id");
  requireNonEmpty(host.name, "Host name");
  requireNonEmpty(host.hostname, "Host hostname");

  if (!VALID_HOST_STATUSES.includes(host.status)) {
    throw new DomainInvariantError(
      `Invalid Host status '${String(host.status)}'`,
    );
  }

  if (host.capabilities.maxConcurrentWorkers < 1) {
    throw new DomainInvariantError(
      "Host maxConcurrentWorkers must be at least 1",
    );
  }
}

/**
 * Validates invariants for a HostWorkspaceBinding.
 */
export function validateHostWorkspaceBinding(
  binding: HostWorkspaceBinding,
  context?: { host?: Host },
): void {
  requireNonEmpty(binding.id, "HostWorkspaceBinding id");
  requireNonEmpty(binding.hostId, "HostWorkspaceBinding hostId");
  requireNonEmpty(binding.workspaceId, "HostWorkspaceBinding workspaceId");

  if (context?.host && context.host.id !== binding.hostId) {
    throw new DomainInvariantError(
      `HostWorkspaceBinding hostId '${binding.hostId}' does not match Host id '${context.host.id}'`,
    );
  }
}

/**
 * Validates invariants for a HostRelease.
 */
export function validateHostRelease(release: HostRelease): void {
  requireNonEmpty(release.version, "HostRelease version");

  if (!VALID_RELEASE_CHANNELS.includes(release.channel)) {
    throw new DomainInvariantError(
      `Invalid HostRelease channel '${release.channel}'. Must be stable, beta, or development`,
    );
  }

  requireNonEmpty(release.packageDigest, "HostRelease packageDigest");
  requireNonEmpty(release.packageR2Key, "HostRelease packageR2Key");
  requireNonEmpty(release.signature, "HostRelease signature");

  if (!release.supportedOS || release.supportedOS.length === 0) {
    throw new DomainInvariantError("HostRelease must support at least one OS");
  }
  if (!release.supportedArch || release.supportedArch.length === 0) {
    throw new DomainInvariantError(
      "HostRelease must support at least one architecture",
    );
  }
}

/**
 * Validates invariants for a V4Worker (catalog entry).
 */
export function validateV4Worker(worker: V4Worker): void {
  requireNonEmpty(worker.id, "V4Worker id");
  requireNonEmpty(worker.displayName, "V4Worker displayName");
  requireNonEmpty(worker.publisher, "V4Worker publisher");

  if (!VALID_WORKER_STATUSES.includes(worker.status)) {
    throw new DomainInvariantError(
      `Invalid V4Worker status '${String(worker.status)}'`,
    );
  }
}

/**
 * Validates invariants for a HostWorkerInstallation.
 */
export function validateHostWorkerInstallation(
  install: HostWorkerInstallation,
): void {
  requireNonEmpty(install.id, "HostWorkerInstallation id");
  requireNonEmpty(install.hostId, "HostWorkerInstallation hostId");
  requireNonEmpty(install.workerId, "HostWorkerInstallation workerId");
  requireNonEmpty(
    install.workerVersionId,
    "HostWorkerInstallation workerVersionId",
  );
  requireNonEmpty(
    install.resolvedVersion,
    "HostWorkerInstallation resolvedVersion",
  );

  if (!VALID_INSTALLATION_STATUSES.includes(install.status)) {
    throw new DomainInvariantError(
      `Invalid HostWorkerInstallation status '${String(install.status)}'`,
    );
  }
}

/**
 * Validates invariants for a CredentialProfile.
 *
 * Key rules:
 * - Private by default.
 * - Workspace-owned profiles must have workspace visibility.
 */
export function validateCredentialProfile(profile: CredentialProfile): void {
  requireNonEmpty(profile.id, "CredentialProfile id");
  requireNonEmpty(profile.ownerId, "CredentialProfile ownerId");
  requireNonEmpty(profile.workspaceId, "CredentialProfile workspaceId");
  requireNonEmpty(profile.workerId, "CredentialProfile workerId");
  requireNonEmpty(profile.displayName, "CredentialProfile displayName");

  if (!["user", "workspace"].includes(profile.ownerType)) {
    throw new DomainInvariantError(
      `Invalid CredentialProfile ownerType '${String(profile.ownerType)}'`,
    );
  }

  if (!["private", "workspace"].includes(profile.visibility)) {
    throw new DomainInvariantError(
      `Invalid CredentialProfile visibility '${String(profile.visibility)}'`,
    );
  }

  // Workspace-owned profiles must be workspace-visible.
  if (profile.ownerType === "workspace" && profile.visibility === "private") {
    throw new DomainInvariantError(
      "Workspace-owned CredentialProfile must have workspace visibility",
    );
  }
}

/**
 * Validates invariants for a CredentialGrant.
 *
 * Key rules:
 * - Self-grants are rejected.
 * - If profile context is provided, private profiles cannot have grants.
 */
export function validateCredentialGrant(
  grant: CredentialGrant,
  context?: { profile?: CredentialProfile },
): void {
  requireNonEmpty(grant.id, "CredentialGrant id");
  requireNonEmpty(
    grant.credentialProfileId,
    "CredentialGrant credentialProfileId",
  );
  requireNonEmpty(grant.granteeId, "CredentialGrant granteeId");
  requireNonEmpty(grant.grantedBy, "CredentialGrant grantedBy");

  if (grant.usePermission !== "use") {
    throw new DomainInvariantError(
      "CredentialGrant supports use permission only; secret-read is forbidden",
    );
  }
  if (
    grant.usageLimit !== null &&
    grant.usageLimit !== undefined &&
    grant.usageLimit < 0
  ) {
    throw new DomainInvariantError(
      "CredentialGrant usageLimit cannot be negative",
    );
  }

  if (!["user", "workspace", "role"].includes(grant.granteeType)) {
    throw new DomainInvariantError(
      `Invalid CredentialGrant granteeType '${String(grant.granteeType)}'`,
    );
  }

  // Self-grant: owner granting to themselves is meaningless.
  if (context?.profile) {
    if (
      context.profile.ownerType === grant.granteeType &&
      context.profile.ownerId === grant.granteeId
    ) {
      throw new DomainInvariantError(
        "CredentialGrant cannot grant to the profile owner (self-grant)",
      );
    }

    // Private profiles do not support grants — must change visibility first.
    if (context.profile.visibility === "private") {
      throw new DomainInvariantError(
        "Cannot create CredentialGrant on a private CredentialProfile. Change visibility to 'workspace' first",
      );
    }
  }
}

/**
 * Validates invariants for a v4 WorkerAssignment.
 *
 * Key invariant: requires hostId + workerId + credentialProfileId.
 * No legacy execution target fields.
 */
export function validateV4Assignment(
  assignment: V4WorkerAssignment,
  context?: { attemptId?: string },
): void {
  requireNonEmpty(assignment.id, "V4WorkerAssignment id");
  requireNonEmpty(assignment.workspaceId, "V4WorkerAssignment workspaceId");
  requireNonEmpty(assignment.projectId, "V4WorkerAssignment projectId");
  requireNonEmpty(assignment.runId, "V4WorkerAssignment runId");
  requireNonEmpty(assignment.taskId, "V4WorkerAssignment taskId");
  requireNonEmpty(assignment.attemptId, "V4WorkerAssignment attemptId");
  requireNonEmpty(
    assignment.requestedByUserId,
    "V4WorkerAssignment requestedByUserId",
  );

  // v4 execution target — the three pillars
  requireNonEmpty(
    assignment.hostId,
    "V4WorkerAssignment hostId (Host is required)",
  );
  requireNonEmpty(
    assignment.workerId,
    "V4WorkerAssignment workerId (Worker is required)",
  );
  requireNonEmpty(
    assignment.credentialProfileId,
    "V4WorkerAssignment credentialProfileId (Credential Profile is required)",
  );

  requireNonEmpty(
    assignment.idempotencyKey,
    "V4WorkerAssignment idempotencyKey",
  );

  if (context?.attemptId && context.attemptId !== assignment.attemptId) {
    throw new DomainInvariantError(
      `V4WorkerAssignment attemptId '${assignment.attemptId}' does not match target attempt '${context.attemptId}'`,
    );
  }
}

/**
 * Validates a V4WorkerAssignmentResult.
 */
export function validateV4AssignmentResult(
  result: V4WorkerAssignmentResult,
  assignment?: V4WorkerAssignment,
): void {
  requireNonEmpty(result.assignmentId, "V4WorkerAssignmentResult assignmentId");
  requireNonEmpty(result.attemptId, "V4WorkerAssignmentResult attemptId");

  if (!result.status) {
    throw new DomainInvariantError(
      "V4WorkerAssignmentResult terminal status is required",
    );
  }

  if (assignment) {
    if (result.assignmentId !== assignment.id) {
      throw new DomainInvariantError(
        `Result assignmentId '${result.assignmentId}' does not match V4WorkerAssignment id '${assignment.id}'`,
      );
    }
    if (result.workspaceId !== assignment.workspaceId) {
      throw new DomainInvariantError(
        `Result workspaceId '${result.workspaceId}' does not match V4WorkerAssignment workspace '${assignment.workspaceId}'`,
      );
    }
    if (
      result.runId !== assignment.runId ||
      result.taskId !== assignment.taskId ||
      result.attemptId !== assignment.attemptId
    ) {
      throw new DomainInvariantError(
        "Result runId/taskId/attemptId does not match V4WorkerAssignment target",
      );
    }
    if (result.hostId !== assignment.hostId) {
      throw new DomainInvariantError(
        `Result hostId '${result.hostId}' does not match V4WorkerAssignment hostId '${assignment.hostId}'`,
      );
    }
    if (result.workerId !== assignment.workerId) {
      throw new DomainInvariantError(
        `Result workerId '${result.workerId}' does not match V4WorkerAssignment workerId '${assignment.workerId}'`,
      );
    }
  }
}
