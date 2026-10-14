export const ASSIGNMENT_ACCEPTANCE_DEADLINE_MS = 30_000;
export const ASSIGNMENT_STARTUP_DEADLINE_MS = 30_000;
/** Default time an accepted assignment may remain queued before startup. */
export const DEFAULT_QUEUE_WAIT_TIMEOUT_MS = 2 * 60_000;

export interface AssignmentCommandDisposition {
  readonly shouldSend: boolean;
  readonly duplicate: boolean;
  readonly terminal: boolean;
  readonly accepted: boolean;
}

/** Classifies a redispatch without ever reopening a terminal assignment. */
export function assignmentCommandDisposition(
  status: string,
): AssignmentCommandDisposition {
  if (
    ["completed", "failed", "cancelled", "timed_out", "lost"].includes(status)
  ) {
    return {
      shouldSend: false,
      duplicate: true,
      terminal: true,
      accepted: true,
    };
  }
  if (["acknowledged", "running"].includes(status)) {
    return {
      shouldSend: false,
      duplicate: true,
      terminal: false,
      accepted: true,
    };
  }
  if (status === "created" || status === "dispatched") {
    return {
      shouldSend: true,
      duplicate: status === "dispatched",
      terminal: false,
      accepted: false,
    };
  }
  return {
    shouldSend: false,
    duplicate: false,
    terminal: false,
    accepted: false,
  };
}

export function assignmentDeliveryExpired(
  status: string,
  createdAt: string,
  now = Date.now(),
  queueWaitTimeoutMs = DEFAULT_QUEUE_WAIT_TIMEOUT_MS,
): boolean {
  return (
    ((status === "created" || status === "dispatched") &&
      now - Date.parse(createdAt) >= ASSIGNMENT_ACCEPTANCE_DEADLINE_MS) ||
    (status === "acknowledged" &&
      now - Date.parse(createdAt) >=
        Math.max(ASSIGNMENT_STARTUP_DEADLINE_MS, queueWaitTimeoutMs))
  );
}
