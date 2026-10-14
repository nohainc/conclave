import { tryLogDiagnosticEvent } from "./observability.js";

/**
 * Event type the Workflow waits for. Cloudflare Workflows event types cannot
 * contain dots, so this is not a protocol message name.
 */
export const ASSIGNMENT_TERMINAL_EVENT_TYPE = "assignment-terminal";

/** After this many failed sends the sweep stops; the waiter's own bounded
 * reconciliation still observes the terminal row in D1. */
export const MAX_WORKFLOW_SIGNAL_ATTEMPTS = 5;

/** Terminal rows older than this are never re-signalled by the sweep. */
const SWEEP_WINDOW_MS = 24 * 60 * 60 * 1000;

const TERMINAL_STATUSES = ["completed", "failed", "cancelled", "timed_out"];
const TERMINAL_SQL = TERMINAL_STATUSES.map((status) => `'${status}'`).join(
  ", ",
);

/**
 * Identity carried by the event. It is a hint, never evidence: the Workflow
 * re-reads the assignment from D1 before acting, so a stale, duplicated or
 * forged payload can at worst cause one extra read.
 */
export interface AssignmentTerminalEventPayload {
  readonly assignmentId: string;
  readonly attemptId: string | null;
  readonly taskId: string;
  readonly runId: string;
  readonly status: string;
}

interface WorkflowInstanceLike {
  sendEvent(event: { type: string; payload?: unknown }): Promise<void>;
}

export interface WorkflowSignalEnv {
  readonly CONCLAVE_DB: D1Database;
  readonly CONCLAVE_RUN_WORKFLOW?: {
    get(id: string): Promise<WorkflowInstanceLike>;
  };
}

export type WorkflowSignalOutcome =
  /** The Workflow accepted the event and the row was stamped. */
  | "signaled"
  /** An earlier call already delivered it. */
  | "already_signaled"
  /** The assignment is not terminal (or does not exist); nothing to send. */
  | "not_terminal"
  /** The run has no Workflow instance to notify; recorded as handled. */
  | "no_instance"
  /** Sending failed; the row stays in the outbox for the sweep. */
  | "failed";

interface SignalRow {
  id: string;
  status: string;
  attempt_id: string | null;
  task_id: string;
  run_id: string;
  workflow_signaled_at: string | null;
  workflow_instance_id: string | null;
}

/**
 * Notifies the Workflow that owns the assignment's run that the assignment is
 * terminal. Never throws and never changes the assignment outcome: callers
 * invoke it only after the terminal state is durable and the Service has been
 * acknowledged, and a failure leaves the row for [sweepUnsignaledTerminals].
 */
export async function signalAssignmentTerminal(
  env: WorkflowSignalEnv,
  assignmentId: string,
  now: () => Date = () => new Date(),
): Promise<WorkflowSignalOutcome> {
  try {
    const row = await env.CONCLAVE_DB.prepare(
      `SELECT wa.id, wa.status, wa.attempt_id, wa.task_id, wa.run_id,
              wa.workflow_signaled_at, r.workflow_instance_id
         FROM worker_assignments wa
         LEFT JOIN runs r ON r.id = wa.run_id
        WHERE wa.id = ?1`,
    )
      .bind(assignmentId)
      .first<SignalRow>();
    if (!row || !TERMINAL_STATUSES.includes(row.status)) return "not_terminal";
    if (row.workflow_signaled_at) return "already_signaled";
    const stamp = async (): Promise<void> => {
      await env.CONCLAVE_DB.prepare(
        `UPDATE worker_assignments SET workflow_signaled_at = ?1
          WHERE id = ?2 AND workflow_signaled_at IS NULL`,
      )
        .bind(now().toISOString(), assignmentId)
        .run();
    };
    if (!row.workflow_instance_id || !env.CONCLAVE_RUN_WORKFLOW) {
      await stamp();
      return "no_instance";
    }
    try {
      const instance = await env.CONCLAVE_RUN_WORKFLOW.get(
        row.workflow_instance_id,
      );
      const payload: AssignmentTerminalEventPayload = {
        assignmentId: row.id,
        attemptId: row.attempt_id,
        taskId: row.task_id,
        runId: row.run_id,
        status: row.status,
      };
      await instance.sendEvent({
        type: ASSIGNMENT_TERMINAL_EVENT_TYPE,
        payload,
      });
    } catch {
      await env.CONCLAVE_DB.prepare(
        `UPDATE worker_assignments
            SET workflow_signal_attempts = workflow_signal_attempts + 1
          WHERE id = ?1 AND workflow_signaled_at IS NULL`,
      )
        .bind(assignmentId)
        .run();
      tryLogDiagnosticEvent({
        assignmentId,
        runId: row.run_id,
        taskId: row.task_id,
        attemptId: row.attempt_id ?? undefined,
        component: "cloud",
        operation: "assignment",
        stage: "workflow_signal",
        severity: "warning",
        errorCode: "workflow_signal_failed",
        retryable: true,
      });
      return "failed";
    }
    await stamp();
    return "signaled";
  } catch {
    // Signalling is an optimisation over the durable state; it must never
    // surface into terminal-result handling.
    return "failed";
  }
}

/**
 * Retries terminal notifications that were not delivered: the outbox. Bounded
 * by age, by attempt count and by [limit] so a Workflow outage cannot turn the
 * cron into an unbounded loop.
 */
export async function sweepUnsignaledTerminals(
  env: WorkflowSignalEnv,
  options: { now?: Date; limit?: number } = {},
): Promise<{ attempted: number; signaled: number }> {
  const now = options.now ?? new Date();
  const limit = options.limit ?? 50;
  const cutoff = new Date(now.getTime() - SWEEP_WINDOW_MS).toISOString();
  const { results } = await env.CONCLAVE_DB.prepare(
    `SELECT id FROM worker_assignments
      WHERE workflow_signaled_at IS NULL
        AND status IN (${TERMINAL_SQL})
        AND workflow_signal_attempts < ?1
        AND updated_at >= ?2
      ORDER BY updated_at
      LIMIT ?3`,
  )
    .bind(MAX_WORKFLOW_SIGNAL_ATTEMPTS, cutoff, limit)
    .all<{ id: string }>();
  let signaled = 0;
  for (const row of results ?? []) {
    const outcome = await signalAssignmentTerminal(env, row.id, () => now);
    if (outcome === "signaled" || outcome === "no_instance") signaled += 1;
  }
  return { attempted: results?.length ?? 0, signaled };
}
