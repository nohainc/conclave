/**
 * Provider-independent lifecycle rules shared by Cloud transition code and
 * tests. `created` is the persisted representation of the public Queued state;
 * `acknowledged` is the persisted Accepted/Starting window until the explicit
 * provider-start acknowledgement arrives.
 */

export const ASSIGNMENT_LIFECYCLE_STATUSES = [
  "created",
  "dispatched",
  "acknowledged",
  "running",
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

const assignmentTransitions: Record<
  AssignmentLifecycleStatus,
  readonly AssignmentLifecycleStatus[]
> = {
  created: ["dispatched", "failed", "cancelled", "timed_out"],
  dispatched: ["acknowledged", "failed", "cancelled", "timed_out"],
  acknowledged: ["running", "failed", "cancelled", "timed_out"],
  running: ["completed", "failed", "cancelled", "timed_out", "lost"],
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

