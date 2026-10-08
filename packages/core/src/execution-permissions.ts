import {
  EXECUTION_PERMISSIONS,
  isExecutionPermission,
  type ExecutionPermission,
} from "@conclave/protocol";

export { EXECUTION_PERMISSIONS, isExecutionPermission };
export type { ExecutionPermission };

/** Cloud authorizes assignments using Space role and Workspace Grant only. */
export function resolveExecutionPermissions(
  spaceRolePermissions: readonly ExecutionPermission[],
  workspaceGrantPermissions: readonly ExecutionPermission[],
): readonly ExecutionPermission[] {
  const grant = new Set(workspaceGrantPermissions);
  return [...new Set(spaceRolePermissions)].filter((permission) =>
    grant.has(permission),
  );
}
