/**
 * Current Thread domain vocabulary.
 *
 * Threads are Space-owned units of collaboration and execution. This
 * module intentionally contains no UI, D1, transport, or provider types.
 */

import type { TurnExecutionConfig } from "./conversation.js";
import { DomainInvariantError } from "./domain-error.js";
import type { SpaceMembership, SpaceRole } from "./space.js";

export type ThreadStatus =
  "active" | "paused" | "blocked" | "completed" | "archived";

export interface ThreadAccessPolicy {
  readonly allowedUserIds: readonly string[];
  readonly allowedSpaceRoles: readonly SpaceRole[];
  readonly allowedPermissions: readonly string[];
}

export const THREAD_ACCESS_PERMISSIONS = [
  "view",
  "discuss",
  "execute",
] as const;
export type ThreadAccessPermission = (typeof THREAD_ACCESS_PERMISSIONS)[number];

export const DEFAULT_THREAD_ACCESS_POLICY: ThreadAccessPolicy = {
  allowedUserIds: [],
  allowedSpaceRoles: ["owner", "collaborator", "viewer"],
  allowedPermissions: [...THREAD_ACCESS_PERMISSIONS],
};

export interface ThreadLead {
  readonly userId: string;
  readonly assignedAt: string;
  readonly assignedByUserId: string;
}

export interface Thread {
  readonly id: string;
  readonly spaceId: string;
  readonly name: string;
  readonly status: ThreadStatus;
  readonly accessPolicy: ThreadAccessPolicy;
  readonly lead: ThreadLead;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface DiscussionMessage {
  readonly id: string;
  readonly threadId: string;
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
  readonly conversationId?: string;
  readonly executionConfig?: TurnExecutionConfig;
  readonly threadId: string;
  readonly requestedByUserId: string;
  readonly mode: WorkRequestMode;
  readonly workflowId: WorkflowId;
  readonly workflowVersion: number;
  /** Immutable copy selected when the Work Request was created. */
  readonly workflowSnapshot: BuiltinWorkflowDefinition;
  /** Immutable execution and prompt inputs captured when submitted. */
  readonly snapshot?: WorkRequestSnapshot;
  readonly status: WorkRequestStatus;
  readonly primaryWorkspaceId: string | null;
  readonly input: Readonly<Record<string, unknown>>;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface WorkRequestSnapshot {
  readonly turnExecutionConfig?: TurnExecutionConfig;
  readonly schemaVersion: 1;
  readonly originalRequest: string;
  readonly attachmentReferences: readonly unknown[];
  readonly workflowId: WorkflowId;
  readonly workflowVersion: number;
  readonly workflowSnapshot: BuiltinWorkflowDefinition;
  readonly resolvedBindings: Readonly<
    Partial<Record<ThreadBindingId, ThreadStepBinding>>
  >;
  readonly spaceInstructions: string;
  readonly threadInstructions: string;
  readonly stepAdditionalInstructions: Partial<Record<StepKind, string>>;
  readonly promptProfileVersions: Partial<Record<StepKind, string>>;
}

export const STEP_KINDS = [
  "chat",
  "research",
  "plan",
  "implement",
  "test",
  "verify",
] as const;
export type StepKind = (typeof STEP_KINDS)[number];

/**
 * Conclave-owned transport for a completed Workflow Step. Workers return plain
 * text; structured fields here are attribution or metadata Conclave can verify.
 */
export interface StepResult {
  readonly text: string;
  readonly status: "completed" | "failed" | "cancelled";
  readonly startedAt: string;
  readonly completedAt: string;
  readonly workerId: string | null;
  readonly workerTypeId: string | null;
  readonly engineVersion: string | null;
  readonly profileDefinitionId: string | null;
  readonly profileReleaseVersion: number | null;
  readonly providerToolVersion: string | null;
  readonly model: string | null;
  readonly reasoningEffort?: string | null;
  readonly artifacts?: readonly string[];
  readonly changedFiles?: readonly string[];
  readonly testStatus?: "passed" | "failed" | "blocked" | "not_run";
}

export const WORKFLOW_IDS = [
  "chat",
  "direct",
  "research",
  "plan_implement",
  "implement_verify",
  "full_cycle",
] as const;
export type WorkflowId = (typeof WORKFLOW_IDS)[number];
export const THREAD_BINDING_IDS = ["direct", ...STEP_KINDS] as const;
export type ThreadBindingId = (typeof THREAD_BINDING_IDS)[number];

export interface ThreadWorkerLabel {
  readonly displayName: string;
  readonly workspaceName: string;
}

export interface ThreadStepBinding {
  readonly workerId?: string;
  /** Presentation snapshot used when the bound Worker is no longer available. */
  readonly workerLabel?: ThreadWorkerLabel;
  readonly model?: string;
  readonly reasoningEffort?: string;
  readonly fallbackWorkerId?: string;
  /** Presentation snapshot used when the fallback Worker is unavailable. */
  readonly fallbackWorkerLabel?: ThreadWorkerLabel;
  readonly additionalInstructions?: string;
}

/** Fixed Thread execution choices; arbitrary task roles are not allowed. */
export interface ThreadWorkConfig {
  readonly defaultWorkflowId: WorkflowId;
  readonly threadInstructions?: string;
  readonly bindings: Readonly<
    Partial<Record<ThreadBindingId, ThreadStepBinding>>
  >;
}

export const DEFAULT_THREAD_WORK_CONFIG: ThreadWorkConfig = {
  defaultWorkflowId: "full_cycle",
  bindings: {},
};

export type WorkflowExecutionMode = "stateless_read" | "stateful_thread";
export type WorkflowExecutionClass = "analysis" | "workspace_action";
export const WORKFLOW_CAPABILITIES = [
  "authorized_context_read",
  "thread_write",
  "test_execution",
  "independent_verification",
] as const;
export type WorkflowCapability = (typeof WORKFLOW_CAPABILITIES)[number];
export type WorkflowReadWritePolicy = "read_only" | "write_thread";
export type WorkflowResultSemantics =
  | "conversation_response"
  | "evidence_summary"
  | "implementation_plan"
  | "thread_changes"
  | "test_report"
  | "verification_report";

export interface BuiltinWorkflowStep {
  readonly kind: StepKind;
  readonly order: number;
  readonly executionMode: WorkflowExecutionMode;
  readonly executionClass: WorkflowExecutionClass;
  readonly requiredCapabilities: readonly WorkflowCapability[];
  readonly readWritePolicy: WorkflowReadWritePolicy;
  readonly timeoutMs: number;
  readonly promptProfileVersion: string;
  /** Fixed by the built-in definition; users cannot author dependencies. */
  readonly dependsOn: readonly StepKind[];
  /** Results from these fixed upstream steps are included as inputs. */
  readonly inputsFrom: readonly StepKind[];
  readonly resultSemantics: WorkflowResultSemantics;
}

export interface BuiltinWorkflowDefinition {
  readonly id: WorkflowId;
  readonly version: number;
  readonly name: string;
  readonly description: string;
  readonly steps: readonly BuiltinWorkflowStep[];
}

const builtinStep = (
  kind: StepKind,
  order: number,
  dependsOn: readonly StepKind[] = [],
  inputsFrom: readonly StepKind[] = dependsOn,
): BuiltinWorkflowStep => ({
  kind,
  order,
  executionMode:
    kind === "chat" || kind === "research" || kind === "plan"
      ? "stateless_read"
      : "stateful_thread",
  executionClass:
    kind === "chat" || kind === "research" || kind === "plan"
      ? "analysis"
      : "workspace_action",
  requiredCapabilities:
    kind === "chat" || kind === "research"
      ? ["authorized_context_read"]
      : kind === "plan"
        ? ["authorized_context_read"]
        : kind === "implement"
          ? ["thread_write"]
          : kind === "test"
            ? ["authorized_context_read", "test_execution"]
            : ["authorized_context_read", "independent_verification"],
  readWritePolicy: kind === "implement" ? "write_thread" : "read_only",
  timeoutMs: 15 * 60 * 1000,
  promptProfileVersion: `${kind}:v1`,
  dependsOn,
  inputsFrom,
  resultSemantics: (
    {
      chat: "conversation_response",
      research: "evidence_summary",
      plan: "implementation_plan",
      implement: "thread_changes",
      test: "test_report",
      verify: "verification_report",
    } satisfies Record<StepKind, WorkflowResultSemantics>
  )[kind],
});

const builtin = (
  id: WorkflowId,
  name: string,
  description: string,
  kinds: readonly StepKind[],
  version = 1,
): BuiltinWorkflowDefinition => ({
  id,
  version,
  name,
  description,
  steps: kinds.map((kind, order) => {
    const preceding = kinds.slice(0, order);
    const inputsFrom = preceding.filter((prior) => {
      switch (kind) {
        case "chat":
        case "research":
          return false;
        case "plan":
          return prior === "research";
        case "implement":
          return prior === "research" || prior === "plan";
        case "test":
          return prior === "plan" || prior === "implement";
        case "verify":
          return true;
      }
    });
    return builtinStep(
      kind,
      order,
      order === 0 ? [] : [kinds[order - 1]!],
      inputsFrom,
    );
  }),
});

const DIRECT_V1 = builtin("direct", "Direct", "Implement the requested work.", [
  "implement",
]);

/** Current version for each built-in ID; immutable history is below. */
export const BUILTIN_WORKFLOWS: Readonly<
  Record<WorkflowId, BuiltinWorkflowDefinition>
> = {
  chat: builtin(
    "chat",
    "Chat",
    "Discuss the request using read-only Thread context.",
    ["chat"],
  ),
  direct: builtin(
    "direct",
    "Work",
    "Implement the requested work.",
    ["implement"],
    2,
  ),
  research: builtin(
    "research",
    "Research",
    "Gather evidence relevant to the request.",
    ["research"],
  ),
  plan_implement: builtin(
    "plan_implement",
    "Plan & Implement",
    "One Worker creates a plan, then a Worker carries it out.",
    ["plan", "implement"],
  ),
  implement_verify: builtin(
    "implement_verify",
    "Implement & Verify",
    "One Worker performs the work, another independently checks it.",
    ["implement", "verify"],
  ),
  full_cycle: builtin(
    "full_cycle",
    "Full Cycle",
    "Research, plan, implement, test, and verify the result.",
    ["research", "plan", "implement", "test", "verify"],
  ),
};

/**
 * Authoritative immutable definitions keyed by stable release reference.
 * Keep older entries when a Workflow gets a newer version so saved Work
 * Request snapshots remain verifiable and executable.
 */
export const BUILTIN_WORKFLOW_CATALOG: Readonly<
  Record<string, BuiltinWorkflowDefinition>
> = {
  "chat:v1": BUILTIN_WORKFLOWS.chat,
  "direct:v1": DIRECT_V1,
  "direct:v2": BUILTIN_WORKFLOWS.direct,
  "research:v1": BUILTIN_WORKFLOWS.research,
  "plan_implement:v1": BUILTIN_WORKFLOWS.plan_implement,
  "implement_verify:v1": BUILTIN_WORKFLOWS.implement_verify,
  "full_cycle:v1": BUILTIN_WORKFLOWS.full_cycle,
};

export function builtinWorkflowReference(
  definition: Pick<BuiltinWorkflowDefinition, "id" | "version">,
): string {
  return `${definition.id}:v${definition.version}`;
}

export interface ThreadExecutionPolicy {
  readonly mode: WorkRequestMode;
  readonly primaryWorkspaceId: string | null;
}

export type ThreadExecutionLeaseStatus = "active" | "released" | "expired";

export interface ThreadExecutionLease {
  readonly id: string;
  readonly threadId: string;
  readonly workRequestId: string;
  readonly workspaceId: string;
  readonly fencingToken: number;
  readonly status: ThreadExecutionLeaseStatus;
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

export function validateThread(
  thread: Thread,
  spaceMemberships: readonly SpaceMembership[],
): void {
  required(thread.id, "Thread id");
  required(thread.spaceId, "Thread spaceId");
  required(thread.name, "Thread name");
  required(thread.lead.userId, "Thread lead userId");
  const lead = spaceMemberships.find(
    (membership) =>
      membership.spaceId === thread.spaceId &&
      membership.userId === thread.lead.userId,
  );
  if (!lead || lead.role === "viewer") {
    throw new DomainInvariantError(
      "Thread lead must be a Space owner or collaborator",
    );
  }
  validateThreadAccessPolicy(thread.accessPolicy, spaceMemberships);
}

/** A Thread policy may only remove Space permissions, never add them. */
export function validateThreadAccessPolicy(
  policy: ThreadAccessPolicy,
  spaceMemberships: readonly SpaceMembership[],
  spacePermissionsByUser: Readonly<Record<string, readonly string[]>> = {},
): void {
  const members = new Map(
    spaceMemberships.map((membership) => [membership.userId, membership]),
  );
  for (const userId of policy.allowedUserIds) {
    const membership = members.get(userId);
    if (!membership || !policy.allowedSpaceRoles.includes(membership.role)) {
      throw new DomainInvariantError(
        "Thread access cannot expand Space membership or contradict its role",
      );
    }
  }
  for (const [userId, permissions] of Object.entries(spacePermissionsByUser)) {
    if (
      policy.allowedUserIds.includes(userId) &&
      policy.allowedPermissions.some(
        (permission) => !permissions.includes(permission),
      )
    ) {
      throw new DomainInvariantError(
        "Thread permissions must be a subset of Space permissions",
      );
    }
  }
}

function canAccessThreadPermission(
  userId: string,
  membership: SpaceMembership | null | undefined,
  thread: Thread,
  permission: ThreadAccessPermission,
): boolean {
  if (!membership || membership.spaceId !== thread.spaceId) return false;
  if (membership.role === "owner") return true;
  if (membership.role === "viewer" && permission !== "view") return false;
  if (
    thread.accessPolicy.allowedUserIds.length > 0 &&
    !thread.accessPolicy.allowedUserIds.includes(userId)
  ) {
    return false;
  }
  if (
    thread.accessPolicy.allowedSpaceRoles.length > 0 &&
    !thread.accessPolicy.allowedSpaceRoles.includes(membership.role)
  ) {
    return false;
  }
  return thread.accessPolicy.allowedPermissions.includes(permission);
}

/** Space membership is always re-evaluated before Thread access. */
export function canViewThread(
  userId: string,
  membership: SpaceMembership | null | undefined,
  thread: Thread,
): boolean {
  return canAccessThreadPermission(userId, membership, thread, "view");
}

export function canDiscussThread(
  userId: string,
  membership: SpaceMembership | null | undefined,
  thread: Thread,
): boolean {
  return canAccessThreadPermission(userId, membership, thread, "discuss");
}

export function canExecuteThread(
  userId: string,
  membership: SpaceMembership | null | undefined,
  thread: Thread,
): boolean {
  return canAccessThreadPermission(userId, membership, thread, "execute");
}

/** Management is Space-owner or assigned Thread-lead authority. */
export function canManageThread(
  userId: string,
  membership: SpaceMembership | null | undefined,
  thread: Thread,
): boolean {
  if (!membership || membership.spaceId !== thread.spaceId) return false;
  if (membership.role === "owner") return true;
  return membership.role === "collaborator" && thread.lead.userId === userId;
}

export function validateDiscussionMessage(message: DiscussionMessage): void {
  required(message.id, "DiscussionMessage id");
  required(message.threadId, "DiscussionMessage threadId");
  required(message.authorUserId, "DiscussionMessage authorUserId");
  required(message.body, "DiscussionMessage body");
}

export function validateWorkRequest(
  request: WorkRequest,
  policy: ThreadExecutionPolicy,
): void {
  required(request.id, "WorkRequest id");
  required(request.threadId, "WorkRequest threadId");
  required(request.requestedByUserId, "WorkRequest requestedByUserId");
  required(request.workflowId, "WorkRequest workflowId");
  positive(request.workflowVersion, "WorkRequest workflowVersion");
  if (
    request.workflowSnapshot.id !== request.workflowId ||
    request.workflowSnapshot.version !== request.workflowVersion
  ) {
    throw new DomainInvariantError(
      "WorkRequest workflow snapshot must match its selected version",
    );
  }
  validateBuiltinWorkflowDefinition(request.workflowSnapshot);
  if (request.snapshot) {
    if (
      request.snapshot.schemaVersion !== 1 ||
      request.snapshot.workflowId !== request.workflowId ||
      request.snapshot.workflowVersion !== request.workflowVersion ||
      request.snapshot.workflowSnapshot.id !== request.workflowId ||
      request.snapshot.workflowSnapshot.version !== request.workflowVersion
    ) {
      throw new DomainInvariantError(
        "WorkRequest execution snapshot must match its selected Workflow",
      );
    }
    validateBuiltinWorkflowDefinition(request.snapshot.workflowSnapshot);
    for (const step of request.snapshot.workflowSnapshot.steps) {
      const bindingId = request.workflowId === "direct" ? "direct" : step.kind;
      if (
        request.snapshot.promptProfileVersions[step.kind] !==
          step.promptProfileVersion ||
        !Object.prototype.hasOwnProperty.call(
          request.snapshot.resolvedBindings,
          bindingId,
        )
      ) {
        throw new DomainInvariantError(
          "WorkRequest snapshot is missing a resolved Step input",
        );
      }
    }
  }
  if (request.mode === "stateful") {
    if (policy.mode !== "stateful" || !policy.primaryWorkspaceId) {
      throw new DomainInvariantError(
        "Stateful WorkRequest requires a Primary Workspace",
      );
    }
    if (!request.primaryWorkspaceId) {
      throw new DomainInvariantError(
        "Stateful WorkRequest requires a Primary Workspace",
      );
    }
    if (request.primaryWorkspaceId !== policy.primaryWorkspaceId) {
      throw new DomainInvariantError(
        "Stateful WorkRequest must use the Thread Primary Workspace",
      );
    }
  }
}

export function validateBuiltinWorkflowDefinition(
  definition: BuiltinWorkflowDefinition,
): void {
  if (!definition || typeof definition !== "object") {
    throw new DomainInvariantError("Built-in Workflow must be an object");
  }
  const exactKeys = (value: object, expected: readonly string[]): boolean => {
    const actual = Object.keys(value).sort();
    return (
      actual.length === expected.length &&
      actual.every((key, index) => key === [...expected].sort()[index])
    );
  };
  if (
    !exactKeys(definition, ["id", "version", "name", "description", "steps"])
  ) {
    throw new DomainInvariantError(
      "Built-in Workflow definition has unsupported fields",
    );
  }
  required(definition.id, "BuiltinWorkflowDefinition id");
  required(definition.name, "BuiltinWorkflowDefinition name");
  required(definition.description, "BuiltinWorkflowDefinition description");
  positive(definition.version, "BuiltinWorkflowDefinition version");
  if (!WORKFLOW_IDS.includes(definition.id)) {
    throw new DomainInvariantError("Unsupported built-in Workflow ID");
  }
  const canonical =
    BUILTIN_WORKFLOW_CATALOG[builtinWorkflowReference(definition)];
  if (!canonical) {
    throw new DomainInvariantError("Unsupported built-in Workflow version");
  }
  if (
    definition.name !== canonical.name ||
    definition.description !== canonical.description ||
    !Array.isArray(definition.steps) ||
    definition.steps.length !== canonical.steps.length
  ) {
    throw new DomainInvariantError(
      "Built-in Workflow definition must match its canonical version",
    );
  }
  for (const [index, step] of definition.steps.entries()) {
    if (
      !step ||
      typeof step !== "object" ||
      !exactKeys(step, [
        "kind",
        "order",
        "executionMode",
        "executionClass",
        "requiredCapabilities",
        "readWritePolicy",
        "timeoutMs",
        "promptProfileVersion",
        "dependsOn",
        "inputsFrom",
        "resultSemantics",
      ])
    ) {
      throw new DomainInvariantError(
        "Built-in Workflow step has unsupported fields",
      );
    }
    const expected = canonical.steps[index]!;
    if (
      step.kind !== expected.kind ||
      step.order !== index ||
      step.executionMode !== expected.executionMode ||
      step.executionClass !== expected.executionClass ||
      step.readWritePolicy !== expected.readWritePolicy ||
      step.resultSemantics !== expected.resultSemantics ||
      !Array.isArray(step.requiredCapabilities) ||
      step.requiredCapabilities.length !==
        expected.requiredCapabilities.length ||
      step.requiredCapabilities.some(
        (capability: WorkflowCapability, capabilityIndex: number) =>
          capability !== expected.requiredCapabilities[capabilityIndex],
      ) ||
      step.timeoutMs !== expected.timeoutMs ||
      step.promptProfileVersion !== expected.promptProfileVersion ||
      !Array.isArray(step.dependsOn) ||
      step.dependsOn.length !== expected.dependsOn.length ||
      step.dependsOn.some(
        (kind: StepKind, dependencyIndex: number) =>
          kind !== expected.dependsOn[dependencyIndex],
      ) ||
      !Array.isArray(step.inputsFrom) ||
      step.inputsFrom.length !== expected.inputsFrom.length ||
      step.inputsFrom.some(
        (kind: StepKind, inputIndex: number) =>
          kind !== expected.inputsFrom[inputIndex],
      )
    ) {
      throw new DomainInvariantError(
        "Built-in Workflow definition must match its canonical version",
      );
    }
    positive(step.timeoutMs, "BuiltinWorkflowStep timeoutMs");
    required(
      step.promptProfileVersion,
      "BuiltinWorkflowStep promptProfileVersion",
    );
  }
}

export function validateThreadExecutionPolicy(
  policy: ThreadExecutionPolicy,
): void {
  if (policy.mode === "stateful" && !policy.primaryWorkspaceId) {
    throw new DomainInvariantError(
      "Stateful Thread execution requires a Primary Workspace",
    );
  }
  if (policy.mode === "stateless" && policy.primaryWorkspaceId) {
    throw new DomainInvariantError(
      "Stateless Thread execution cannot define a Primary Workspace",
    );
  }
}

export function validateThreadLeases(
  thread: Pick<Thread, "id">,
  leases: readonly ThreadExecutionLease[],
): void {
  const active = leases.filter(
    (lease) => lease.threadId === thread.id && lease.status === "active",
  );
  if (active.length > 1) {
    throw new DomainInvariantError(
      "A Thread can have only one active execution lease",
    );
  }
  for (const lease of leases) {
    required(lease.id, "ThreadExecutionLease id");
    required(lease.threadId, "ThreadExecutionLease threadId");
    positive(lease.fencingToken, "ThreadExecutionLease fencingToken");
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
export function serializeEntity<T extends object>(entity: T): string {
  return JSON.stringify(sortObject(entity));
}

export function deserializeEntity<T>(serialized: string): T {
  const value: unknown = JSON.parse(serialized);
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainInvariantError("Serialized entity must be an object");
  }
  return value as T;
}
