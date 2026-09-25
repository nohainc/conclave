/**
 * WD-0: canonical filesystem ownership contract for Workstreams.
 *
 * This module deliberately does not resolve paths or create directories. It
 * freezes the identity and ownership rules that those later runtime features
 * must implement.
 */

export interface WorkstreamFilesystemIdentity {
  readonly projectId: string;
  readonly workstreamId: string;
}

export const WORKSTREAM_FILESYSTEM_INVARIANTS = Object.freeze({
  runtimeCardinality: "one_per_os_user_installation",
  workRootOwnership: "workspace_runtime_local",
  directoryIdentity: ["projectId", "workstreamId"] as const,
  persistentLocalState: true,
  workerCwd: "runtime_resolved",
  repositories: "worker_managed",
  mutation: "one_per_workstream",
  parallelism: "different_workstreams",
  forbiddenPathComponents: [
    "projectName",
    "workstreamName",
    "userEmail",
    "userDisplayName",
    "workspaceId",
    "workerName",
    "repositoryName",
  ] as const,
});

function required(value: string, field: string): void {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${field} is required for Workstream filesystem identity`);
  }
}

/** Validates the only logical identity accepted by the filesystem contract. */
export function validateWorkstreamFilesystemIdentity(
  identity: WorkstreamFilesystemIdentity,
): void {
  required(identity.projectId, "projectId");
  required(identity.workstreamId, "workstreamId");
}

/**
 * Produces a collision-safe logical key without claiming to be a filesystem
 * path. The runtime path resolver is intentionally deferred to WD-2.
 */
export function workstreamFilesystemIdentityKey(
  identity: WorkstreamFilesystemIdentity,
): string {
  validateWorkstreamFilesystemIdentity(identity);
  return `${identity.projectId.length}:${identity.projectId}${identity.workstreamId.length}:${identity.workstreamId}`;
}

export function sameWorkstreamFilesystemIdentity(
  left: WorkstreamFilesystemIdentity,
  right: WorkstreamFilesystemIdentity,
): boolean {
  return (
    workstreamFilesystemIdentityKey(left) ===
    workstreamFilesystemIdentityKey(right)
  );
}
