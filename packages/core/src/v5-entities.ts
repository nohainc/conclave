/**
 * Canonical Architecture v5 domain vocabulary.
 *
 * Project is collaboration. Workspace is execution. These types are
 * intentionally independent from transport and persistence representations.
 */

import { DomainInvariantError } from "./entities.js";

export type ExecutionWorkspaceStatus =
  "enrolled" | "online" | "offline" | "busy" | "draining" | "revoked";

/** One user-owned execution environment backed by one runtime. */
export interface ExecutionWorkspace {
  readonly id: string;
  readonly ownerUserId: string;
  readonly name: string;
  readonly status: ExecutionWorkspaceStatus;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface WorkspaceRuntimeIdentity {
  readonly id: string;
  readonly workspaceId: string;
  readonly machineFingerprint: string;
  readonly platform: "macos" | "linux" | "windows";
  readonly architecture: "arm64" | "x64";
  readonly credentialKeyRef: string;
  readonly createdAt: string;
  readonly revokedAt: string | null;
}

export interface WorkspaceSession {
  readonly id: string;
  readonly workspaceId: string;
  readonly runtimeIdentityId: string;
  readonly connectedAt: string;
  readonly lastHeartbeatAt: string;
  readonly disconnectedAt: string | null;
  readonly clientVersion: string;
  readonly protocolVersion: string;
}

export interface WorkspaceEnrollment {
  readonly id: string;
  readonly workspaceId: string;
  readonly tokenHash: string;
  readonly expiresAt: string;
  readonly usedAt: string | null;
  readonly revokedAt: string | null;
  readonly createdByUserId: string;
}

export type WorkspaceWorkerInstallationStatus =
  | "absent"
  | "requested"
  | "installing"
  | "ready"
  | "updating"
  | "degraded"
  | "failed"
  | "removing";

export interface WorkspaceWorkerInstallation {
  readonly id: string;
  readonly workspaceId: string;
  readonly workerId: string;
  readonly workerVersionId: string;
  readonly resolvedVersion: string;
  readonly status: WorkspaceWorkerInstallationStatus;
  readonly installedAt: string | null;
  readonly updatedAt: string;
}

export type ProjectRole = "owner" | "collaborator" | "viewer";

/** A person participating in a Project; this is not Workspace access. */
export interface ProjectMembership {
  readonly id: string;
  readonly projectId: string;
  readonly userId: string;
  readonly role: ProjectRole;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export type ProjectInvitationStatus =
  "pending" | "accepted" | "revoked" | "expired";

export interface ProjectInvitation {
  readonly id: string;
  readonly projectId: string;
  readonly invitedEmail: string;
  readonly role: Exclude<ProjectRole, "owner">;
  readonly invitedByUserId: string;
  readonly status: ProjectInvitationStatus;
  readonly expiresAt: string;
  readonly createdAt: string;
}

export type WorkspaceProjectGrantStatus =
  "active" | "suspended" | "revoked" | "expired";
export type WorkspaceProjectGrantScope =
  "project_repository" | "selected_paths" | "full_workspace";

export interface WorkspaceRepositoryMapping {
  readonly repositoryId: string;
  readonly workspacePath: string;
}

export interface WorkspacePathMapping {
  readonly projectPath: string;
  readonly workspacePath: string;
}

export interface WorkspaceNetworkPolicy {
  readonly mode: "deny_all" | "allowlist";
  readonly allowedHosts: readonly string[];
}

export interface WorkspaceConcurrencyPolicy {
  readonly maxConcurrentAssignments: number;
}

export interface WorkspaceBudgetPolicy {
  readonly maxCostMicros: number | null;
  readonly maxInputTokens: number | null;
  readonly maxOutputTokens: number | null;
}

/** Explicitly authorizes one Project to execute through one Workspace. */
export interface WorkspaceProjectGrant {
  readonly id: string;
  readonly projectId: string;
  readonly workspaceId: string;
  readonly grantedByUserId: string;
  readonly status: WorkspaceProjectGrantStatus;
  readonly scope: WorkspaceProjectGrantScope;
  readonly repositoryMappings: readonly WorkspaceRepositoryMapping[];
  readonly pathMappings: readonly WorkspacePathMapping[];
  readonly allowedWorkerIds: readonly string[];
  readonly allowedWorkerCapabilities: readonly string[];
  readonly allowedPermissions: readonly string[];
  readonly networkPolicy: WorkspaceNetworkPolicy;
  readonly concurrency: WorkspaceConcurrencyPolicy;
  readonly budget: WorkspaceBudgetPolicy | null;
  readonly requiresStepUp: boolean;
  readonly expiresAt: string | null;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface EffectiveWorkspacePermission {
  readonly projectId: string;
  readonly workspaceId: string;
  readonly grantId: string;
  readonly requesterUserId: string;
  readonly scope: WorkspaceProjectGrantScope;
  readonly permissions: readonly string[];
  readonly repositoryMappings: readonly WorkspaceRepositoryMapping[];
  readonly pathMappings: readonly WorkspacePathMapping[];
  readonly networkPolicy: WorkspaceNetworkPolicy;
  readonly concurrency: WorkspaceConcurrencyPolicy;
  readonly budget: WorkspaceBudgetPolicy | null;
  readonly snapshotAt: string;
}

/** Account use is granted independently from Workspace execution access. */
export interface ProjectAccountGrant {
  readonly id: string;
  readonly projectId: string;
  readonly accountId: string;
  readonly grantedByUserId: string;
  readonly granteeUserId: string | null;
  readonly status: "active" | "revoked" | "expired";
  readonly expiresAt: string | null;
  readonly createdAt: string;
}

export type AiAccountSharingMode = "private_only" | "project_shared";
export type AiAccountStatus =
  | "setup_required"
  | "ready"
  | "expired"
  | "error"
  | "revoked";

/** A User-owned provider identity; execution Workspace placement is storage, not ownership. */
export interface AiAccount {
  readonly id: string;
  readonly ownerUserId: string;
  readonly workerId: string;
  readonly executionWorkspaceId: string | null;
  readonly displayName: string;
  readonly authType: "none" | "api_key" | "oauth" | "session_token" | "local";
  readonly secretLocation: "none" | "workspace_secure_store";
  readonly status: AiAccountStatus;
  readonly sharingMode: AiAccountSharingMode;
  readonly providerMetadata: Readonly<Record<string, unknown>>;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface ResolvedExecutionTarget {
  readonly projectId: string;
  readonly workspaceId: string;
  readonly workspaceRuntimeIdentityId: string;
  readonly workspaceWorkerInstallationId: string;
  readonly workerId: string;
  readonly resolvedWorkerVersion: string;
  readonly aiAccountId: string;
  readonly model?: string;
  readonly config: Record<string, unknown>;
  readonly effectivePermissions: readonly string[];
  readonly effectivePermission: EffectiveWorkspacePermission;
}

export type WorkerAssignmentStatus =
  | "created"
  | "dispatched"
  | "acknowledged"
  | "running"
  | "completed"
  | "failed"
  | "cancelled"
  | "timed_out";

/** Immutable v5 execution snapshot. */
export interface WorkerAssignment {
  readonly id: string;
  readonly projectId: string;
  readonly workspaceId: string;
  readonly runId: string;
  readonly taskId: string;
  readonly attemptId: string;
  readonly requestedByUserId: string;
  readonly target: ResolvedExecutionTarget;
  readonly status: WorkerAssignmentStatus;
  readonly input: Record<string, unknown>;
  readonly idempotencyKey: string;
  readonly timeoutMs: number;
  readonly createdAt: string;
  readonly updatedAt: string;
}

function requireNonEmpty(value: string, field: string): void {
  if (!value || value.trim().length === 0) {
    throw new DomainInvariantError(`${field} is required`);
  }
}

export function validateExecutionWorkspace(
  workspace: ExecutionWorkspace,
): void {
  requireNonEmpty(workspace.id, "ExecutionWorkspace id");
  requireNonEmpty(workspace.ownerUserId, "ExecutionWorkspace ownerUserId");
  requireNonEmpty(workspace.name, "ExecutionWorkspace name");
  if (!workspace.status)
    throw new DomainInvariantError("ExecutionWorkspace status is required");
}

/** Exactly one owner is required; ownership is represented by ProjectMembership. */
export function validateProjectMemberships(
  projectId: string,
  memberships: readonly ProjectMembership[],
): void {
  requireNonEmpty(projectId, "Project id");
  const projectMemberships = memberships.filter(
    (membership) => membership.projectId === projectId,
  );
  if (projectMemberships.length !== memberships.length) {
    throw new DomainInvariantError(
      "ProjectMembership references a different Project",
    );
  }
  if (
    new Set(projectMemberships.map((membership) => membership.userId)).size !==
    projectMemberships.length
  ) {
    throw new DomainInvariantError(
      "ProjectMembership userId must be unique within a Project",
    );
  }
  if (
    projectMemberships.filter((membership) => membership.role === "owner")
      .length !== 1
  ) {
    throw new DomainInvariantError("Project must have exactly one owner");
  }
}

export function validateWorkspaceProjectGrant(
  grant: WorkspaceProjectGrant,
): void {
  requireNonEmpty(grant.id, "WorkspaceProjectGrant id");
  requireNonEmpty(grant.projectId, "WorkspaceProjectGrant projectId");
  requireNonEmpty(grant.workspaceId, "WorkspaceProjectGrant workspaceId");
  requireNonEmpty(
    grant.grantedByUserId,
    "WorkspaceProjectGrant grantedByUserId",
  );
  if (
    grant.status === "active" &&
    grant.expiresAt &&
    Date.parse(grant.expiresAt) <= Date.now()
  ) {
    throw new DomainInvariantError(
      "Active WorkspaceProjectGrant cannot be expired",
    );
  }
}

export function validateWorkspaceWorkerInstallation(
  installation: WorkspaceWorkerInstallation,
): void {
  requireNonEmpty(installation.id, "WorkspaceWorkerInstallation id");
  requireNonEmpty(
    installation.workspaceId,
    "WorkspaceWorkerInstallation workspaceId",
  );
  requireNonEmpty(
    installation.workerId,
    "WorkspaceWorkerInstallation workerId",
  );
  requireNonEmpty(
    installation.resolvedVersion,
    "WorkspaceWorkerInstallation resolvedVersion",
  );
}

export interface WorkspaceExecutionAuthorizationInput {
  readonly requesterUserId: string;
  readonly projectId: string;
  readonly workspace: ExecutionWorkspace;
  readonly projectMemberships: readonly ProjectMembership[];
  readonly grant?: WorkspaceProjectGrant;
  readonly now?: string;
  readonly stepUpVerified?: boolean;
}

/** Project membership alone never grants another user's Workspace access. */
export function canExecuteProjectThroughWorkspace(
  input: WorkspaceExecutionAuthorizationInput,
): boolean {
  const membership = input.projectMemberships.find(
    (candidate) =>
      candidate.projectId === input.projectId &&
      candidate.userId === input.requesterUserId,
  );
  if (!membership || membership.role === "viewer") return false;
  if (input.workspace.ownerUserId === input.requesterUserId) return true;
  const grant = input.grant;
  if (
    !grant ||
    grant.projectId !== input.projectId ||
    grant.workspaceId !== input.workspace.id
  )
    return false;
  if (grant.status !== "active") return false;
  if (grant.scope === "full_workspace" && !input.stepUpVerified) return false;
  const now = Date.parse(input.now ?? new Date().toISOString());
  return grant.expiresAt === null || Date.parse(grant.expiresAt) > now;
}

export function canUseProjectAccount(input: {
  readonly requesterUserId: string;
  readonly projectId: string;
  readonly accountOwnerUserId: string;
  readonly projectMemberships: readonly ProjectMembership[];
  readonly grant?: ProjectAccountGrant;
  readonly now?: string;
}): boolean {
  const membership = input.projectMemberships.find(
    (candidate) =>
      candidate.projectId === input.projectId &&
      candidate.userId === input.requesterUserId,
  );
  if (!membership || membership.role === "viewer") return false;
  if (input.accountOwnerUserId === input.requesterUserId) return true;
  const grant = input.grant;
  if (
    !grant ||
    grant.projectId !== input.projectId ||
    grant.granteeUserId !== input.requesterUserId
  )
    return false;
  if (grant.status !== "active") return false;
  const now = Date.parse(input.now ?? new Date().toISOString());
  return grant.expiresAt === null || Date.parse(grant.expiresAt) > now;
}

/** Effective permissions are the set intersection of every active boundary. */
export function intersectPermissions(
  ...permissionSets: readonly (readonly string[])[]
): readonly string[] {
  if (permissionSets.length === 0) return [];
  const [first, ...rest] = permissionSets;
  const otherSets = rest.map((permissions) => new Set(permissions));
  return [...new Set(first)].filter((permission) =>
    otherSets.every((set) => set.has(permission)),
  );
}

function normalizedPath(path: string): string[] {
  const segments: string[] = [];
  for (const segment of path.replaceAll("\\", "/").split("/")) {
    if (!segment || segment === ".") continue;
    if (segment === "..") {
      if (segments.length === 0) {
        throw new DomainInvariantError(
          "Path escapes the allowed Workspace root",
        );
      }
      segments.pop();
      continue;
    }
    segments.push(segment);
  }
  return segments;
}

function pathWithin(root: string, target: string): boolean {
  const rootSegments = normalizedPath(root);
  const targetSegments = normalizedPath(target);
  return rootSegments.every(
    (segment, index) => targetSegments[index] === segment,
  );
}

export interface WorkspacePathAuthorizationInput {
  readonly scope: WorkspaceProjectGrantScope;
  readonly pathMappings: readonly WorkspacePathMapping[];
  readonly requestedPath: string;
  readonly symlinkTargetPath?: string | null;
}

/** Rejects traversal and symlink escapes before a runtime receives a path. */
export function assertWorkspacePathAllowed(
  input: WorkspacePathAuthorizationInput,
): void {
  const mappings =
    input.scope === "full_workspace"
      ? [{ projectPath: "/", workspacePath: "/" }]
      : input.pathMappings;
  const mapping = mappings.find((candidate) =>
    pathWithin(candidate.projectPath, input.requestedPath),
  );
  if (!mapping) {
    throw new DomainInvariantError(
      "Requested path is outside the granted Project path",
    );
  }
  const relative = normalizedPath(input.requestedPath).slice(
    normalizedPath(mapping.projectPath).length,
  );
  const resolvedWorkspacePath = `/${[
    ...normalizedPath(mapping.workspacePath),
    ...relative,
  ].join("/")}`;
  if (!pathWithin(mapping.workspacePath, resolvedWorkspacePath)) {
    throw new DomainInvariantError(
      "Requested path escapes the granted Workspace path",
    );
  }
  if (
    input.symlinkTargetPath &&
    !pathWithin(mapping.workspacePath, input.symlinkTargetPath)
  ) {
    throw new DomainInvariantError(
      "Symlink target escapes the granted Workspace path",
    );
  }
}

export interface EffectivePermissionInput {
  readonly requesterUserId: string;
  readonly projectId: string;
  readonly workspace: ExecutionWorkspace;
  readonly projectMembership: ProjectMembership;
  readonly grant: WorkspaceProjectGrant;
  readonly workerId: string;
  readonly workerCapabilities: readonly string[];
  readonly workerManifestPermissions: readonly string[];
  readonly workspaceLocalPermissions: readonly string[];
  readonly projectPolicyPermissions: readonly string[];
  readonly stepUpVerified?: boolean;
  readonly now: string;
}

/** Resolves one immutable permission object for scheduler and runtime use. */
export function resolveEffectivePermission(
  input: EffectivePermissionInput,
): EffectiveWorkspacePermission {
  const { grant } = input;
  if (input.projectMembership.role === "viewer") {
    throw new DomainInvariantError(
      "Project viewers cannot execute assignments",
    );
  }
  if (
    grant.projectId !== input.projectId ||
    grant.workspaceId !== input.workspace.id ||
    grant.status !== "active"
  ) {
    throw new DomainInvariantError(
      "WorkspaceProjectGrant is not active for this Project and Workspace",
    );
  }
  if (grant.expiresAt && Date.parse(grant.expiresAt) <= Date.parse(input.now)) {
    throw new DomainInvariantError("WorkspaceProjectGrant has expired");
  }
  if (grant.scope === "full_workspace" && !input.stepUpVerified) {
    throw new DomainInvariantError(
      "full_workspace grants require step-up verification",
    );
  }
  if (
    grant.allowedWorkerIds.length > 0 &&
    !grant.allowedWorkerIds.includes(input.workerId)
  ) {
    throw new DomainInvariantError(
      "Worker is not allowed by WorkspaceProjectGrant",
    );
  }
  if (
    grant.allowedWorkerCapabilities.some(
      (capability) => !input.workerCapabilities.includes(capability),
    )
  ) {
    throw new DomainInvariantError(
      "Worker does not declare all granted capabilities",
    );
  }
  const permissions = resolveEffectivePermissions({
    projectMemberPermissions: projectRolePermissions(
      input.projectMembership.role,
    ),
    workspaceGrantPermissions: grant.allowedPermissions,
    workerManifestPermissions: input.workerManifestPermissions,
    workspaceLocalPermissions: input.workspaceLocalPermissions,
    projectPolicyPermissions: input.projectPolicyPermissions,
  });
  return {
    projectId: input.projectId,
    workspaceId: input.workspace.id,
    grantId: grant.id,
    requesterUserId: input.requesterUserId,
    scope: grant.scope,
    permissions: [...permissions],
    repositoryMappings: grant.repositoryMappings.map((mapping) => ({
      ...mapping,
    })),
    pathMappings: grant.pathMappings.map((mapping) => ({ ...mapping })),
    networkPolicy: {
      mode: grant.networkPolicy.mode,
      allowedHosts: [...grant.networkPolicy.allowedHosts],
    },
    concurrency: { ...grant.concurrency },
    budget: grant.budget ? { ...grant.budget } : null,
    snapshotAt: input.now,
  };
}

function projectRolePermissions(role: ProjectRole): readonly string[] {
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

export function resolveEffectivePermissions(input: {
  readonly projectMemberPermissions: readonly string[];
  readonly workspaceGrantPermissions: readonly string[];
  readonly workerManifestPermissions: readonly string[];
  readonly workspaceLocalPermissions: readonly string[];
  readonly projectPolicyPermissions: readonly string[];
}): readonly string[] {
  return intersectPermissions(
    input.projectMemberPermissions,
    input.workspaceGrantPermissions,
    input.workerManifestPermissions,
    input.workspaceLocalPermissions,
    input.projectPolicyPermissions,
  );
}

export function validateWorkerAssignment(assignment: WorkerAssignment): void {
  requireNonEmpty(assignment.id, "WorkerAssignment id");
  requireNonEmpty(assignment.projectId, "WorkerAssignment projectId");
  requireNonEmpty(assignment.workspaceId, "WorkerAssignment workspaceId");
  requireNonEmpty(
    assignment.requestedByUserId,
    "WorkerAssignment requestedByUserId",
  );
  requireNonEmpty(assignment.idempotencyKey, "WorkerAssignment idempotencyKey");
  if (
    assignment.target.projectId !== assignment.projectId ||
    assignment.target.workspaceId !== assignment.workspaceId
  ) {
    throw new DomainInvariantError(
      "WorkerAssignment target does not match assignment scope",
    );
  }
  if (assignment.target.effectivePermissions.length === 0) {
    throw new DomainInvariantError(
      "WorkerAssignment requires effective permissions",
    );
  }
}
