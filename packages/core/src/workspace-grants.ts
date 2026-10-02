/** Project authorization to execute work through a Workspace. */

export type WorkspaceProjectGrantStatus =
  "active" | "suspended" | "revoked" | "expired";

export interface WorkspaceNetworkPolicy {
  readonly mode: "deny_all" | "allowlist";
  readonly allowedHosts: readonly string[];
}

export interface WorkspaceConcurrencyPolicy {
  readonly maxConcurrentAssignments: number;
}

export interface WorkspaceProjectGrant {
  readonly id: string;
  readonly projectId: string;
  readonly workspaceId: string;
  readonly grantedByUserId: string;
  readonly status: WorkspaceProjectGrantStatus;
  readonly allowedWorkerIds: readonly string[];
  readonly allowedWorkerCapabilities: readonly string[];
  readonly allowedPermissions: readonly string[];
  readonly networkPolicy: WorkspaceNetworkPolicy;
  readonly concurrency: WorkspaceConcurrencyPolicy;
  readonly expiresAt: string | null;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface EffectiveWorkspacePermission {
  readonly projectId: string;
  readonly workspaceId: string;
  readonly grantId: string;
  readonly requesterUserId: string;
  readonly permissions: readonly string[];
  readonly networkPolicy: WorkspaceNetworkPolicy;
  readonly concurrency: WorkspaceConcurrencyPolicy;
  readonly snapshotAt: string;
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

export function resolveEffectivePermissions(input: {
  readonly projectMemberPermissions: readonly string[];
  readonly workspaceGrantPermissions: readonly string[];
  readonly workerPermissions: readonly string[];
  readonly workspaceLocalPermissions: readonly string[];
  readonly projectPolicyPermissions: readonly string[];
}): readonly string[] {
  return intersectPermissions(
    input.projectMemberPermissions,
    input.workspaceGrantPermissions,
    input.workerPermissions,
    input.workspaceLocalPermissions,
    input.projectPolicyPermissions,
  );
}
