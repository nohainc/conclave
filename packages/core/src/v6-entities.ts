/**
 * Canonical Architecture v6 Workstream vocabulary.
 *
 * Workstreams are Project-owned units of collaboration and execution. This
 * module intentionally contains no UI, D1, transport, or provider types.
 */

import { DomainInvariantError } from "./entities.js";
import type { ProjectMembership, ProjectRole } from "./v5-entities.js";

export type WorkstreamStatus =
  "active" | "paused" | "blocked" | "completed" | "archived";

export interface WorkstreamAccessPolicy {
  readonly allowedUserIds: readonly string[];
  readonly allowedProjectRoles: readonly ProjectRole[];
  readonly allowedPermissions: readonly string[];
}

export const WORKSTREAM_ACCESS_PERMISSIONS = [
  "view",
  "discuss",
  "execute",
] as const;
export type WorkstreamAccessPermission =
  (typeof WORKSTREAM_ACCESS_PERMISSIONS)[number];

export const DEFAULT_WORKSTREAM_ACCESS_POLICY: WorkstreamAccessPolicy = {
  allowedUserIds: [],
  allowedProjectRoles: ["owner", "collaborator", "viewer"],
  allowedPermissions: [...WORKSTREAM_ACCESS_PERMISSIONS],
};

export interface WorkstreamLead {
  readonly userId: string;
  readonly assignedAt: string;
  readonly assignedByUserId: string;
}

export interface Workstream {
  readonly id: string;
  readonly projectId: string;
  readonly name: string;
  readonly status: WorkstreamStatus;
  readonly accessPolicy: WorkstreamAccessPolicy;
  readonly lead: WorkstreamLead;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface DiscussionMessage {
  readonly id: string;
  readonly workstreamId: string;
  readonly authorUserId: string;
  readonly body: string;
  readonly createdAt: string;
  readonly editedAt: string | null;
}

export type WorkRequestStatus =
  "queued" | "running" | "waiting" | "completed" | "failed" | "cancelled";

export type WorkRequestMode = "stateless" | "stateful";

export interface WorkRequest {
  readonly id: string;
  readonly workstreamId: string;
  readonly requestedByUserId: string;
  readonly mode: WorkRequestMode;
  readonly workflowDefinitionId: string;
  readonly workflowVersionId: string;
  /** Immutable copy selected when the Work Request was created. */
  readonly workflowVersionSnapshot: WorkflowVersion;
  readonly status: WorkRequestStatus;
  readonly primaryWorkspaceId: string | null;
  /**
   * Historical compatibility field. New Work Requests resolve their local
   * directory from Project ID + Workstream ID and must leave this null.
   */
  readonly checkoutId?: string | null;
  readonly input: Readonly<Record<string, unknown>>;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface WorkflowDefinition {
  readonly id: string;
  readonly projectId: string;
  readonly name: string;
  readonly description: string;
  readonly currentVersionId: string | null;
  readonly createdByUserId: string;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface WorkflowVersion {
  readonly id: string;
  readonly workflowDefinitionId: string;
  readonly version: number;
  readonly steps: readonly WorkflowStep[];
  readonly createdByUserId: string;
  readonly createdAt: string;
}

export type WorkflowExecutionClass = "stateless_read" | "stateful_workstream";
export type WorkflowApproval = "none" | "human" | "project_owner";

export interface WorkflowOutputContract {
  readonly contentType: string;
  readonly requiredFields: readonly string[];
  readonly artifactTypes: readonly string[];
}

export interface WorkflowStep {
  readonly id: string;
  readonly name: string;
  readonly role: string;
  readonly requiredCapabilities: readonly string[];
  readonly executionClass: WorkflowExecutionClass;
  readonly order: number;
  readonly dependsOn: readonly string[];
  readonly independentFrom: readonly string[];
  readonly approval: WorkflowApproval;
  readonly timeoutMs: number;
  readonly outputContract: WorkflowOutputContract;
}

export const BUILT_IN_WORKFLOW_NAMES = [
  "Research",
  "Review",
  "Implementation",
  "Implementation + Test + Review",
  "Research + Implementation",
  "Full Cycle",
] as const;
export type BuiltInWorkflowName = (typeof BUILT_IN_WORKFLOW_NAMES)[number];

const builtInStep = (
  id: string,
  name: string,
  role: string,
  executionClass: WorkflowExecutionClass,
  order: number,
  dependsOn: readonly string[] = [],
): WorkflowStep => ({
  id,
  name,
  role,
  requiredCapabilities: [],
  executionClass,
  order,
  dependsOn,
  independentFrom: [],
  approval: "none",
  timeoutMs: 15 * 60 * 1000,
  outputContract: {
    contentType: "application/json",
    requiredFields: ["summary"],
    artifactTypes: [],
  },
});

const builtInVersion = (
  name: BuiltInWorkflowName,
  steps: readonly WorkflowStep[],
): WorkflowVersion => ({
  id: `builtin-${name.toLowerCase().replaceAll(/[^a-z0-9]+/g, "-")}-v1`,
  workflowDefinitionId: `builtin-${name.toLowerCase().replaceAll(/[^a-z0-9]+/g, "-")}`,
  version: 1,
  steps,
  createdByUserId: "system",
  createdAt: "2026-01-01T00:00:00.000Z",
});

/** Immutable built-in workflow versions used by the initial runner. */
export const BUILT_IN_WORKFLOW_VERSIONS: Readonly<
  Record<BuiltInWorkflowName, WorkflowVersion>
> = {
  Research: builtInVersion("Research", [
    builtInStep("research", "Research", "research", "stateless_read", 0),
  ]),
  Review: builtInVersion("Review", [
    builtInStep("review", "Review", "review", "stateless_read", 0),
  ]),
  Implementation: builtInVersion("Implementation", [
    builtInStep(
      "implementation",
      "Implementation",
      "implementation",
      "stateful_workstream",
      0,
    ),
  ]),
  "Implementation + Test + Review": builtInVersion(
    "Implementation + Test + Review",
    [
      builtInStep(
        "implementation",
        "Implementation",
        "implementation",
        "stateful_workstream",
        0,
      ),
      builtInStep("test", "Test", "test", "stateless_read", 1, [
        "implementation",
      ]),
      builtInStep("review", "Review", "review", "stateless_read", 2, ["test"]),
    ],
  ),
  "Research + Implementation": builtInVersion("Research + Implementation", [
    builtInStep("research", "Research", "research", "stateless_read", 0),
    builtInStep(
      "implementation",
      "Implementation",
      "implementation",
      "stateful_workstream",
      1,
      ["research"],
    ),
  ]),
  "Full Cycle": builtInVersion("Full Cycle", [
    builtInStep("research", "Research", "research", "stateless_read", 0),
    builtInStep(
      "implementation",
      "Implementation",
      "implementation",
      "stateful_workstream",
      1,
      ["research"],
    ),
    builtInStep("test", "Test", "test", "stateless_read", 2, [
      "implementation",
    ]),
    builtInStep("review", "Review", "review", "stateless_read", 3, ["test"]),
  ]),
};

export interface WorkstreamExecutionPolicy {
  readonly mode: WorkRequestMode;
  readonly primaryWorkspaceId: string | null;
  /** @deprecated Checkout provisioning is no longer part of active v6. */
  readonly requireCheckout: boolean;
  readonly maxConcurrentWorkRequests: number;
}

export type WorkstreamCheckoutStatus =
  "provisioning" | "ready" | "stale" | "deleted";

export interface WorkstreamCheckout {
  /** @deprecated Historical v6 control-plane entity; not an execution path. */
  readonly id: string;
  readonly workstreamId: string;
  readonly workspaceId: string;
  readonly repositoryId: string;
  readonly revision: string;
  readonly relativePath: string;
  readonly status: WorkstreamCheckoutStatus;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface WorkstreamCheckpoint {
  readonly id: string;
  readonly workstreamId: string;
  readonly checkoutId: string;
  readonly sequence: number;
  readonly revision: string;
  readonly summary: string;
  readonly createdByWorkRequestId: string;
  readonly createdAt: string;
}

export type WorkstreamExecutionLeaseStatus = "active" | "released" | "expired";

export interface WorkstreamExecutionLease {
  readonly id: string;
  readonly workstreamId: string;
  readonly checkoutId: string;
  readonly workRequestId: string;
  readonly workspaceId: string;
  readonly fencingToken: number;
  readonly status: WorkstreamExecutionLeaseStatus;
  readonly acquiredAt: string;
  readonly expiresAt: string;
  readonly releasedAt: string | null;
}

function required(value: string, field: string): void {
  if (!value || value.trim().length === 0) {
    throw new DomainInvariantError(`${field} is required`);
  }
}

function positive(value: number, field: string): void {
  if (!Number.isInteger(value) || value <= 0) {
    throw new DomainInvariantError(`${field} must be a positive integer`);
  }
}

export function validateWorkstream(
  workstream: Workstream,
  projectMemberships: readonly ProjectMembership[],
): void {
  required(workstream.id, "Workstream id");
  required(workstream.projectId, "Workstream projectId");
  required(workstream.name, "Workstream name");
  required(workstream.lead.userId, "Workstream lead userId");
  const lead = projectMemberships.find(
    (membership) =>
      membership.projectId === workstream.projectId &&
      membership.userId === workstream.lead.userId,
  );
  if (!lead || lead.role === "viewer") {
    throw new DomainInvariantError(
      "Workstream lead must be a Project owner or collaborator",
    );
  }
  validateWorkstreamAccessPolicy(workstream.accessPolicy, projectMemberships);
}

/** A Workstream policy may only remove Project permissions, never add them. */
export function validateWorkstreamAccessPolicy(
  policy: WorkstreamAccessPolicy,
  projectMemberships: readonly ProjectMembership[],
  projectPermissionsByUser: Readonly<Record<string, readonly string[]>> = {},
): void {
  const members = new Map(
    projectMemberships.map((membership) => [membership.userId, membership]),
  );
  for (const userId of policy.allowedUserIds) {
    const membership = members.get(userId);
    if (!membership || !policy.allowedProjectRoles.includes(membership.role)) {
      throw new DomainInvariantError(
        "Workstream access cannot expand Project membership or contradict its role",
      );
    }
  }
  for (const [userId, permissions] of Object.entries(
    projectPermissionsByUser,
  )) {
    if (
      policy.allowedUserIds.includes(userId) &&
      policy.allowedPermissions.some(
        (permission) => !permissions.includes(permission),
      )
    ) {
      throw new DomainInvariantError(
        "Workstream permissions must be a subset of Project permissions",
      );
    }
  }
}

function canAccessWorkstreamPermission(
  userId: string,
  membership: ProjectMembership | null | undefined,
  workstream: Workstream,
  permission: WorkstreamAccessPermission,
): boolean {
  if (!membership || membership.projectId !== workstream.projectId)
    return false;
  if (membership.role === "owner") return true;
  if (membership.role === "viewer" && permission !== "view") return false;
  if (
    workstream.accessPolicy.allowedUserIds.length > 0 &&
    !workstream.accessPolicy.allowedUserIds.includes(userId)
  ) {
    return false;
  }
  if (
    workstream.accessPolicy.allowedProjectRoles.length > 0 &&
    !workstream.accessPolicy.allowedProjectRoles.includes(membership.role)
  ) {
    return false;
  }
  return workstream.accessPolicy.allowedPermissions.includes(permission);
}

/** Project membership is always re-evaluated before Workstream access. */
export function canViewWorkstream(
  userId: string,
  membership: ProjectMembership | null | undefined,
  workstream: Workstream,
): boolean {
  return canAccessWorkstreamPermission(userId, membership, workstream, "view");
}

export function canDiscussWorkstream(
  userId: string,
  membership: ProjectMembership | null | undefined,
  workstream: Workstream,
): boolean {
  return canAccessWorkstreamPermission(
    userId,
    membership,
    workstream,
    "discuss",
  );
}

export function canExecuteWorkstream(
  userId: string,
  membership: ProjectMembership | null | undefined,
  workstream: Workstream,
): boolean {
  return canAccessWorkstreamPermission(
    userId,
    membership,
    workstream,
    "execute",
  );
}

/** Management is Project-owner or assigned Workstream-lead authority. */
export function canManageWorkstream(
  userId: string,
  membership: ProjectMembership | null | undefined,
  workstream: Workstream,
): boolean {
  if (!membership || membership.projectId !== workstream.projectId)
    return false;
  if (membership.role === "owner") return true;
  return (
    membership.role === "collaborator" && workstream.lead.userId === userId
  );
}

export function validateDiscussionMessage(message: DiscussionMessage): void {
  required(message.id, "DiscussionMessage id");
  required(message.workstreamId, "DiscussionMessage workstreamId");
  required(message.authorUserId, "DiscussionMessage authorUserId");
  required(message.body, "DiscussionMessage body");
}

export function validateWorkRequest(
  request: WorkRequest,
  policy: WorkstreamExecutionPolicy,
): void {
  required(request.id, "WorkRequest id");
  required(request.workstreamId, "WorkRequest workstreamId");
  required(request.requestedByUserId, "WorkRequest requestedByUserId");
  required(request.workflowDefinitionId, "WorkRequest workflowDefinitionId");
  required(request.workflowVersionId, "WorkRequest workflowVersionId");
  if (
    request.workflowVersionSnapshot.id !== request.workflowVersionId ||
    request.workflowVersionSnapshot.workflowDefinitionId !==
      request.workflowDefinitionId
  ) {
    throw new DomainInvariantError(
      "WorkRequest workflow snapshot must match its selected version",
    );
  }
  validateWorkflowVersion(request.workflowVersionSnapshot);
  if (request.mode === "stateful") {
    if (policy.mode !== "stateful" || !policy.primaryWorkspaceId) {
      throw new DomainInvariantError(
        "Stateful WorkRequest requires a Primary Workspace",
      );
    }
    if (!request.primaryWorkspaceId) {
      throw new DomainInvariantError("Stateful WorkRequest requires a Primary Workspace");
    }
    if (request.primaryWorkspaceId !== policy.primaryWorkspaceId) {
      throw new DomainInvariantError(
        "Stateful WorkRequest must use the Workstream Primary Workspace",
      );
    }
  }
  if (request.checkoutId) {
    throw new DomainInvariantError(
      "WorkRequest cannot use the historical Checkout control plane",
    );
  }
}

export function validateWorkflowVersion(version: WorkflowVersion): void {
  required(version.id, "WorkflowVersion id");
  required(
    version.workflowDefinitionId,
    "WorkflowVersion workflowDefinitionId",
  );
  positive(version.version, "WorkflowVersion version");
  const stepIds = new Set(version.steps.map((step) => step.id));
  const orders = version.steps.map((step) => step.order);
  if (stepIds.size !== version.steps.length) {
    throw new DomainInvariantError("WorkflowStep id must be unique");
  }
  if (new Set(orders).size !== orders.length) {
    throw new DomainInvariantError("WorkflowStep order must be unique");
  }
  for (const step of version.steps) {
    required(step.id, "WorkflowStep id");
    required(step.name, "WorkflowStep name");
    required(step.role, "WorkflowStep role");
    positive(step.timeoutMs, "WorkflowStep timeoutMs");
    if (!Number.isInteger(step.order) || step.order < 0) {
      throw new DomainInvariantError("WorkflowStep order must be non-negative");
    }
    for (const dependencyId of step.dependsOn) {
      if (!stepIds.has(dependencyId)) {
        throw new DomainInvariantError(
          "WorkflowStep dependency must reference a step in the version",
        );
      }
    }
    for (const independentId of step.independentFrom) {
      if (!stepIds.has(independentId) || independentId === step.id) {
        throw new DomainInvariantError(
          "WorkflowStep independence must reference another step in the version",
        );
      }
      if (step.dependsOn.includes(independentId)) {
        throw new DomainInvariantError(
          "WorkflowStep cannot be both dependent and independent",
        );
      }
    }
  }

  const byId = new Map(version.steps.map((step) => [step.id, step]));
  const visiting = new Set<string>();
  const visited = new Set<string>();
  const visit = (stepId: string): void => {
    if (visiting.has(stepId)) {
      throw new DomainInvariantError(
        "WorkflowStep dependencies contain a cycle",
      );
    }
    if (visited.has(stepId)) return;
    visiting.add(stepId);
    const step = byId.get(stepId)!;
    for (const dependencyId of step.dependsOn) {
      visit(dependencyId);
    }
    visiting.delete(stepId);
    visited.add(stepId);
  };
  for (const step of version.steps) visit(step.id);

  for (const step of version.steps) {
    for (const dependencyId of step.dependsOn) {
      const dependency = byId.get(dependencyId)!;
      if (dependency.order >= step.order) {
        throw new DomainInvariantError(
          "WorkflowStep dependencies must execute before the dependent step",
        );
      }
    }
  }

  for (const step of version.steps) {
    if (
      step.executionClass === "stateful_workstream" &&
      step.independentFrom.some((stepId) => {
        const other = byId.get(stepId);
        return other?.executionClass === "stateful_workstream";
      })
    ) {
      throw new DomainInvariantError(
        "Stateful Workstream steps cannot be marked independent",
      );
    }
  }
}

/** Editing a workflow creates a new immutable, monotonically newer version. */
export function validateNextWorkflowVersion(
  previous: WorkflowVersion,
  next: WorkflowVersion,
): void {
  validateWorkflowVersion(previous);
  validateWorkflowVersion(next);
  if (next.workflowDefinitionId !== previous.workflowDefinitionId) {
    throw new DomainInvariantError(
      "Workflow versions must belong to the same definition",
    );
  }
  if (next.id === previous.id || next.version !== previous.version + 1) {
    throw new DomainInvariantError(
      "Editing a Workflow must create the next immutable version",
    );
  }
}

export function validateWorkstreamExecutionPolicy(
  policy: WorkstreamExecutionPolicy,
): void {
  if (policy.mode === "stateful" && !policy.primaryWorkspaceId) {
    throw new DomainInvariantError(
      "Stateful Workstream execution requires a Primary Workspace",
    );
  }
  if (policy.mode === "stateless" && policy.primaryWorkspaceId) {
    throw new DomainInvariantError(
      "Stateless Workstream execution cannot define a Primary Workspace",
    );
  }
  positive(policy.maxConcurrentWorkRequests, "maxConcurrentWorkRequests");
}

export function validateWorkstreamCheckout(checkout: WorkstreamCheckout): void {
  required(checkout.id, "WorkstreamCheckout id");
  required(checkout.workstreamId, "WorkstreamCheckout workstreamId");
  required(checkout.workspaceId, "WorkstreamCheckout workspaceId");
  required(checkout.repositoryId, "WorkstreamCheckout repositoryId");
  required(checkout.revision, "WorkstreamCheckout revision");
  if (
    checkout.relativePath.startsWith("/") ||
    checkout.relativePath.includes("..")
  ) {
    throw new DomainInvariantError(
      "WorkstreamCheckout path must be relative and contained",
    );
  }
}

export function validateWorkstreamCheckpoints(
  checkout: WorkstreamCheckout,
  checkpoints: readonly WorkstreamCheckpoint[],
): void {
  const relevant = checkpoints
    .filter((checkpoint) => checkpoint.checkoutId === checkout.id)
    .sort((left, right) => left.sequence - right.sequence);
  relevant.forEach((checkpoint, index) => {
    if (
      checkpoint.workstreamId !== checkout.workstreamId ||
      checkpoint.sequence !== index + 1
    ) {
      throw new DomainInvariantError(
        "Workstream checkpoint sequence must be linear per Checkout",
      );
    }
  });
}

export function validateWorkstreamLeases(
  checkout: WorkstreamCheckout,
  leases: readonly WorkstreamExecutionLease[],
): void {
  const active = leases.filter(
    (lease) => lease.checkoutId === checkout.id && lease.status === "active",
  );
  if (active.length > 1) {
    throw new DomainInvariantError(
      "A Workstream Checkout can have only one active execution lease",
    );
  }
  for (const lease of leases) {
    required(lease.id, "WorkstreamExecutionLease id");
    positive(lease.fencingToken, "WorkstreamExecutionLease fencingToken");
  }
}

function sortObject(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortObject);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, entry]) => [key, sortObject(entry)]),
    );
  }
  return value;
}

/** Stable JSON helpers for domain snapshots; persistence remains external. */
export function serializeV6Entity<T extends object>(entity: T): string {
  return JSON.stringify(sortObject(entity));
}

export function deserializeV6Entity<T>(serialized: string): T {
  const value: unknown = JSON.parse(serialized);
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainInvariantError("Serialized v6 entity must be an object");
  }
  return value as T;
}
