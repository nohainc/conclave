/**
 * Provider-independent lifecycle rules shared by Cloud transition code and
 * tests. This is the single source of truth for assignment status changes:
 * every Cloud writer derives its conditional-UPDATE source set from
 * `assignmentSourceStatuses(target)` instead of spelling status lists inline.
 *
 * Persisted statuses and the public lifecycle vocabulary:
 *
 * | Public state | Persisted `status`           | Evidence that causes it               |
 * | ------------ | ---------------------------- | ------------------------------------- |
 * | Created      | `created`                    | assignment row inserted               |
 * | Dispatched   | `dispatched`                 | Gateway queued `assignment.start`     |
 * | Acknowledged | `acknowledged`               | `assignment.ack` accepted (admission) |
 * | Queued       | `acknowledged` (projection)  | Service-local, no Cloud signal        |
 * | Starting     | `acknowledged` (projection)  | Service-local, no Cloud signal        |
 * | Running      | `running`                    | `assignment.start.ack` (provider)     |
 * | Stopping     | `revocation_pending`         | Cloud decided the work must not run;  |
 * |              |                              | `assignment.cancel` is outstanding    |
 * | Unresolved   | `reconciling`                | revocation unconfirmed; the process   |
 * |              |                              | may still be alive                    |
 * | Terminal     | completed/failed/cancelled/  | result, error, cancellation, or       |
 * |              | timed_out/lost               | confirmed revocation                  |
 *
 * Queued and Starting happen inside the Service between admission and the
 * provider-start acknowledgement. Cloud has no protocol signal for them, so
 * they project onto `acknowledged`; no duplicate state is stored for display.
 */

export const ASSIGNMENT_LIFECYCLE_STATUSES = [
  "created",
  "dispatched",
  "acknowledged",
  "running",
  "revocation_pending",
  "reconciling",
  "completed",
  "failed",
  "cancelled",
  "timed_out",
  "lost",
] as const;
export type AssignmentLifecycleStatus =
  (typeof ASSIGNMENT_LIFECYCLE_STATUSES)[number];

/**
 * Attempts use the same monotonic execution lifecycle as their assignment.
 * The current schema projects an attempt through worker_assignments, but the
 * type keeps attempt identity distinct from a retry counter.
 */
export const ATTEMPT_LIFECYCLE_STATUSES = ASSIGNMENT_LIFECYCLE_STATUSES;
export type AttemptLifecycleStatus = AssignmentLifecycleStatus;

export const TASK_LIFECYCLE_STATUSES = [
  "queued",
  "running",
  "waiting",
  "completed",
  "failed",
  "cancelled",
] as const;
export type TaskLifecycleStatus = (typeof TASK_LIFECYCLE_STATUSES)[number];

export const RUN_LIFECYCLE_STATUSES = [
  "created",
  "running",
  "paused",
  "completed",
  "failed",
  "cancelled",
] as const;
export type RunLifecycleStatus = (typeof RUN_LIFECYCLE_STATUSES)[number];

export const WORK_REQUEST_LIFECYCLE_STATUSES = [
  "queued",
  "running",
  "waiting",
  "completed",
  "failed",
  "cancelled",
] as const;
export type WorkRequestLifecycleStatus =
  (typeof WORK_REQUEST_LIFECYCLE_STATUSES)[number];

const terminalAssignmentStatuses = new Set<AssignmentLifecycleStatus>([
  "completed",
  "failed",
  "cancelled",
  "timed_out",
  "lost",
]);

/**
 * Evidence reaching Cloud is deliberately independent of ordering. A later
 * milestone implies every earlier one: a provider-start acknowledgement proves
 * the Service admitted the assignment, and a result proves the provider ran.
 * Transitions may therefore skip forward but never backward, and terminal
 * statuses have no outgoing edges.
 */
const assignmentTransitions: Record<
  AssignmentLifecycleStatus,
  readonly AssignmentLifecycleStatus[]
> = {
  created: [
    "dispatched",
    "acknowledged",
    "running",
    "completed",
    "failed",
    "cancelled",
    "timed_out",
  ],
  dispatched: [
    "acknowledged",
    "running",
    "revocation_pending",
    "completed",
    "failed",
    "cancelled",
    "timed_out",
  ],
  acknowledged: [
    "running",
    "revocation_pending",
    "completed",
    "failed",
    "cancelled",
    "timed_out",
  ],
  running: [
    "revocation_pending",
    "completed",
    "failed",
    "cancelled",
    "timed_out",
    "lost",
  ],
  // Cloud has decided the work must not run but has no proof the process is
  // gone. It leaves this state only on Service evidence (a cancellation
  // confirmation, a terminal report) or by escalating to `reconciling`. A
  // late result is still accepted: the provider finished before the stop.
  revocation_pending: [
    "reconciling",
    "completed",
    "failed",
    "cancelled",
    "timed_out",
  ],
  reconciling: ["completed", "failed", "cancelled", "timed_out"],
  completed: [],
  failed: [],
  cancelled: [],
  timed_out: [],
  lost: [],
};

const taskTransitions: Record<
  TaskLifecycleStatus,
  readonly TaskLifecycleStatus[]
> = {
  queued: ["running", "waiting", "completed", "failed", "cancelled"],
  running: ["waiting", "completed", "failed", "cancelled"],
  waiting: ["queued", "running", "completed", "failed", "cancelled"],
  completed: [],
  failed: [],
  cancelled: [],
};

const runTransitions: Record<
  RunLifecycleStatus,
  readonly RunLifecycleStatus[]
> = {
  created: ["running", "cancelled", "failed"],
  running: ["paused", "completed", "failed", "cancelled"],
  paused: ["running", "completed", "failed", "cancelled"],
  completed: [],
  failed: [],
  cancelled: [],
};

const workRequestTransitions: Record<
  WorkRequestLifecycleStatus,
  readonly WorkRequestLifecycleStatus[]
> = {
  queued: ["running", "waiting", "completed", "failed", "cancelled"],
  running: ["waiting", "completed", "failed", "cancelled"],
  waiting: ["queued", "running", "completed", "failed", "cancelled"],
  completed: [],
  failed: ["queued", "cancelled"],
  cancelled: [],
};

/**
 * Kinds of acknowledgement that reach Cloud. They are distinct on purpose:
 *
 * - `delivery`: the transport accepted the command (WebSocket write or
 *   long-poll queue). It never changes `status` beyond `dispatched`.
 * - `admission`: the Service durably accepted the assignment
 *   (`assignment.ack` with `accepted: true`).
 * - `provider_start`: the provider process is confirmed running
 *   (`assignment.start.ack`).
 */
export const ASSIGNMENT_EVIDENCE_KINDS = [
  "delivery",
  "admission",
  "provider_start",
] as const;
export type AssignmentEvidenceKind = (typeof ASSIGNMENT_EVIDENCE_KINDS)[number];

const evidenceTargets: Record<
  AssignmentEvidenceKind,
  AssignmentLifecycleStatus
> = {
  delivery: "dispatched",
  admission: "acknowledged",
  provider_start: "running",
};

/** The status an acknowledgement of [kind] moves an assignment toward. */
export function assignmentStatusForEvidence(
  kind: AssignmentEvidenceKind,
): AssignmentLifecycleStatus {
  return evidenceTargets[kind];
}

/**
 * Statuses a conditional UPDATE may move *from* when targeting [target]. The
 * target itself is excluded, so replaying the same evidence matches no row
 * and cannot refresh `updated_at` (which drives startup deadlines).
 */
export function assignmentSourceStatuses(
  target: AssignmentLifecycleStatus,
): readonly AssignmentLifecycleStatus[] {
  return ASSIGNMENT_LIFECYCLE_STATUSES.filter(
    (from) => from !== target && assignmentTransitions[from].includes(target),
  );
}

/** Statuses that admit no further transition (terminal and immutable). */
export const ASSIGNMENT_TERMINAL_STATUSES = [
  "completed",
  "failed",
  "cancelled",
  "timed_out",
  "lost",
] as const satisfies readonly AssignmentLifecycleStatus[];

/** Statuses in which Cloud has asked the Service to stop but lacks proof. */
export const ASSIGNMENT_REVOCATION_STATUSES = [
  "revocation_pending",
  "reconciling",
] as const satisfies readonly AssignmentLifecycleStatus[];

/** Every non-terminal status: capacity, sync and recovery treat these as live. */
export const ASSIGNMENT_ACTIVE_STATUSES = ASSIGNMENT_LIFECYCLE_STATUSES.filter(
  (status) => !terminalAssignmentStatuses.has(status),
);

export function isRevocationAssignmentStatus(
  status: AssignmentLifecycleStatus,
): boolean {
  return (ASSIGNMENT_REVOCATION_STATUSES as readonly string[]).includes(status);
}

export function canTransitionAssignment(
  from: AssignmentLifecycleStatus,
  to: AssignmentLifecycleStatus,
): boolean {
  return from === to || assignmentTransitions[from].includes(to);
}

export function canTransitionAttempt(
  from: AttemptLifecycleStatus,
  to: AttemptLifecycleStatus,
): boolean {
  return canTransitionAssignment(from, to);
}

export function canTransitionTask(
  from: TaskLifecycleStatus,
  to: TaskLifecycleStatus,
): boolean {
  return from === to || taskTransitions[from].includes(to);
}

export function canTransitionRun(
  from: RunLifecycleStatus,
  to: RunLifecycleStatus,
): boolean {
  return from === to || runTransitions[from].includes(to);
}

export function canTransitionWorkRequest(
  from: WorkRequestLifecycleStatus,
  to: WorkRequestLifecycleStatus,
): boolean {
  return from === to || workRequestTransitions[from].includes(to);
}

export function isTerminalAssignmentStatus(
  status: AssignmentLifecycleStatus,
): boolean {
  return terminalAssignmentStatuses.has(status);
}

export function isActiveAssignmentStatus(
  status: AssignmentLifecycleStatus,
): boolean {
  return !isTerminalAssignmentStatus(status);
}
