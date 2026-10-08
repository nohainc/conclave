import {
  isExecutionPermission,
  type ExecutionPermission,
} from "./execution-permissions.js";
import { WORKER_INPUT_CAPABILITIES } from "./worker-inventory.js";
import { WORKFLOW_CAPABILITIES } from "./thread.js";

/** Space authorization to execute work through a Workspace. */

export type WorkspaceSpaceGrantStatus =
  "active" | "suspended" | "revoked" | "expired";

export const WORKSPACE_SPACE_GRANT_STATUSES = [
  "active",
  "suspended",
  "revoked",
  "expired",
] as const satisfies readonly WorkspaceSpaceGrantStatus[];

export const WORKSPACE_GRANT_CAPABILITIES = [
  ...WORKFLOW_CAPABILITIES,
  ...WORKER_INPUT_CAPABILITIES,
  "thread_read",
  "durable_session",
] as const;

export function isWorkspaceSpaceGrantStatus(
  value: unknown,
): value is WorkspaceSpaceGrantStatus {
  return (
    typeof value === "string" &&
    (WORKSPACE_SPACE_GRANT_STATUSES as readonly string[]).includes(value)
  );
}

export function canTransitionWorkspaceSpaceGrantStatus(
  from: WorkspaceSpaceGrantStatus,
  to: WorkspaceSpaceGrantStatus,
): boolean {
  if (from === to) return true;
  if (from === "active")
    return to === "suspended" || to === "revoked" || to === "expired";
  if (from === "suspended")
    return to === "active" || to === "revoked" || to === "expired";
  return false;
}

export function isWorkspaceGrantCapability(value: unknown): value is string {
  return (
    typeof value === "string" &&
    (WORKSPACE_GRANT_CAPABILITIES as readonly string[]).includes(value)
  );
}

export function isWorkspaceWorkerId(value: unknown): value is string {
  return (
    typeof value === "string" &&
    /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(value)
  );
}

export function validateWorkspaceGrantPermissions(
  value: unknown,
): value is readonly ExecutionPermission[] {
  return (
    Array.isArray(value) &&
    value.length <= 4 &&
    value.every(isExecutionPermission) &&
    new Set(value).size === value.length
  );
}

export function validateWorkspaceGrantCapabilities(
  value: unknown,
): value is readonly string[] {
  return (
    Array.isArray(value) &&
    value.length <= WORKSPACE_GRANT_CAPABILITIES.length &&
    value.every(isWorkspaceGrantCapability) &&
    new Set(value).size === value.length
  );
}

export function validateWorkspaceGrantWorkerIds(
  value: unknown,
): value is readonly string[] {
  return (
    Array.isArray(value) &&
    value.length <= 64 &&
    value.every(isWorkspaceWorkerId) &&
    new Set(value).size === value.length
  );
}

export interface WorkspaceNetworkPolicy {
  readonly mode: "deny_all" | "allowlist";
  readonly allowedHosts: readonly string[];
}

export interface WorkspaceConcurrencyPolicy {
  readonly maxConcurrentAssignments: number;
}

export function validateWorkspaceConcurrencyPolicy(
  value: unknown,
): value is WorkspaceConcurrencyPolicy {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const policy = value as Record<string, unknown>;
  return (
    Object.keys(policy).length === 1 &&
    Object.hasOwn(policy, "maxConcurrentAssignments") &&
    Number.isSafeInteger(policy.maxConcurrentAssignments) &&
    Number(policy.maxConcurrentAssignments) >= 1 &&
    Number(policy.maxConcurrentAssignments) <= 1024
  );
}

function isWorkspaceNetworkHost(value: unknown): value is string {
  if (typeof value !== "string" || value.length > 253 || value !== value.trim())
    return false;
  const labels = value.split(".");
  if (labels.length < 2 || value !== value.toLowerCase()) return false;
  if (
    labels.some(
      (label) =>
        label.length < 1 ||
        label.length > 63 ||
        !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label),
    )
  ) {
    return false;
  }
  const topLevelDomain = labels.at(-1)!;
  return /^[a-z](?:[a-z-]*[a-z])?$/.test(topLevelDomain);
}

export function validateWorkspaceNetworkPolicy(
  value: unknown,
): value is WorkspaceNetworkPolicy {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const policy = value as Record<string, unknown>;
  if (
    Object.keys(policy).length !== 2 ||
    !Object.hasOwn(policy, "mode") ||
    !Object.hasOwn(policy, "allowedHosts") ||
    !Array.isArray(policy.allowedHosts) ||
    policy.allowedHosts.length > 256 ||
    !policy.allowedHosts.every(isWorkspaceNetworkHost) ||
    new Set(policy.allowedHosts).size !== policy.allowedHosts.length
  ) {
    return false;
  }
  if (policy.mode === "deny_all") return policy.allowedHosts.length === 0;
  return policy.mode === "allowlist" && policy.allowedHosts.length > 0;
}

export interface WorkspaceSpaceGrant {
  readonly id: string;
  readonly spaceId: string;
  readonly workspaceId: string;
  readonly grantedByUserId: string;
  readonly status: WorkspaceSpaceGrantStatus;
  readonly allowedWorkerIds: readonly string[];
  readonly allowedWorkerCapabilities: readonly string[];
  readonly allowedPermissions: readonly ExecutionPermission[];
  readonly networkPolicy: WorkspaceNetworkPolicy;
  readonly concurrency: WorkspaceConcurrencyPolicy;
  readonly expiresAt: string | null;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface EffectiveWorkspacePermission {
  readonly spaceId: string;
  readonly workspaceId: string;
  readonly grantId: string;
  readonly requesterUserId: string;
  readonly permissions: readonly ExecutionPermission[];
  readonly networkPolicy: WorkspaceNetworkPolicy;
  readonly concurrency: WorkspaceConcurrencyPolicy;
  readonly snapshotAt: string;
}
