/**
 * Cloud-derived execution presentation for the Work tab (V9 Phase 7).
 *
 * Everything here is a pure function of one assignment row. The UI renders
 * the result and never infers state from elapsed time or from the last
 * activity event. Nothing in the output exposes `localDiagnostic` or the
 * Service-side diagnostic text; only fixed public strings leave this module.
 */

export type ExecutionPhase =
  /** Work Request accepted; no assignment exists yet. */
  | "submitted"
  /** Assignment persisted; waiting for the Workspace Service to be ready. */
  | "waiting_for_service"
  /** Command handed to the transport; not yet acknowledged. */
  | "delivering"
  /** Workspace Service acknowledged the command. */
  | "delivered"
  /** Service accepted it and is waiting for a Worker slot. */
  | "queued"
  /** Slot/permit granted; provider CLI is starting. Not Running yet. */
  | "starting"
  /** Provider start was observed. The only phase that may say Running. */
  | "running"
  | "completed"
  | "failed"
  | "cancelled"
  /** Stop of a possibly-running Worker is not confirmed. */
  | "uncertain";

export const TERMINAL_EXECUTION_PHASES: ReadonlySet<ExecutionPhase> = new Set([
  "completed",
  "failed",
  "cancelled",
]);

export type FailureCategory =
  | "service_unavailable"
  | "sync_incomplete"
  | "worker_unavailable"
  | "capacity_exceeded"
  | "profile_incompatible"
  | "space_folder_confirmation_required"
  | "provider_start_failed"
  | "startup_timeout"
  | "execution_failed"
  | "state_uncertain";

/** Fixed public wording. Never built from provider or Service text. */
export const FAILURE_CATEGORY_MESSAGES: Readonly<
  Record<FailureCategory, string>
> = {
  service_unavailable: "Workspace Service is offline",
  sync_incomplete: "Workspace is reconnecting",
  worker_unavailable: "Worker is not ready",
  capacity_exceeded:
    "No Worker slot became free in time. Retry when another request finishes",
  profile_incompatible: "Worker Profile is incompatible",
  space_folder_confirmation_required:
    "A folder with this Space's name already exists and is not empty",
  provider_start_failed: "AI provider could not start",
  startup_timeout: "Worker startup timed out",
  execution_failed: "Worker execution failed",
  state_uncertain: "Checking whether execution is still active",
};

export const EXECUTION_PHASE_LABELS: Readonly<Record<ExecutionPhase, string>> =
  {
    submitted: "Submitted",
    waiting_for_service: "Queued",
    delivering: "Queued",
    delivered: "Queued",
    queued: "Queued",
    starting: "Starting",
    running: "Running",
    completed: "Completed",
    failed: "Failed",
    cancelled: "Cancelled",
    uncertain: "Checking",
  };

/** Sub-line shown under the phase label. */
export const EXECUTION_PHASE_DETAILS: Readonly<
  Record<ExecutionPhase, string | null>
> = {
  submitted: "Request received by Conclave",
  waiting_for_service: "Waiting for the Workspace Service to be ready",
  delivering: "Sending to your Workspace",
  delivered: "Worker accepted the request",
  queued: "All Worker slots are busy; starting when one is free",
  starting: "Starting your worker",
  running: null,
  completed: null,
  failed: null,
  cancelled: null,
  uncertain: FAILURE_CATEGORY_MESSAGES.state_uncertain,
};

export interface RetryAdvice {
  readonly allowed: boolean;
  /** Previous execution may already have performed side effects. */
  readonly requiresConfirmation: boolean;
}

export interface ExecutionAssignmentEvidence {
  /** `worker_assignments.status`; undefined when no assignment exists. */
  readonly assignmentStatus?: string | null;
  /** `workflow_tasks.status`; used only when there is no assignment. */
  readonly taskStatus?: string | null;
  readonly dispatchedAt?: string | null;
  readonly acknowledgedAt?: string | null;
  readonly startPermitIssuedAt?: string | null;
  readonly startPermitRequired?: boolean | null;
  readonly runningAt?: string | null;
  readonly startupStage?: string | null;
  /** Raw `worker_assignments.error_json`. */
  readonly errorJson?: string | null;
  /** Canonical public error code, when the step failed. */
  readonly errorCode?: string | null;
}

export interface ExecutionPresentation {
  readonly executionPhase: ExecutionPhase;
  readonly executionPhaseLabel: string;
  readonly executionPhaseDetail: string | null;
  readonly failureCategory: FailureCategory | null;
  readonly failureCategoryMessage: string | null;
  readonly retry: RetryAdvice | null;
}

const TERMINAL_ASSIGNMENT_STATUSES = new Set([
  "completed",
  "failed",
  "cancelled",
  "timed_out",
  "lost",
]);

const WAITING_STARTUP_STAGES = new Set([
  "worker_resolved",
  "profile_ready",
  "waiting_for_space",
  "queued_for_slot",
]);

const STARTING_STARTUP_STAGES = new Set([
  "slot_reserved",
  "engine_spawned",
  "engine_initialized",
]);

interface ParsedError {
  readonly diagnosticStage: string | null;
  readonly revocationObservedStatus: string | null;
}

function parseError(errorJson: string | null | undefined): ParsedError {
  let revocationObservedStatus: string | null = null;
  let diagnosticStage: string | null = null;
  if (!errorJson) return { diagnosticStage, revocationObservedStatus };
  try {
    const parsed = JSON.parse(errorJson) as Record<string, unknown>;
    const revocation = parsed.revocation as Record<string, unknown> | undefined;
    if (revocation && typeof revocation.observedStatus === "string") {
      revocationObservedStatus = revocation.observedStatus;
    }
    const error = parsed.error as Record<string, unknown> | undefined;
    const details = error?.details as Record<string, unknown> | undefined;
    if (typeof details?.diagnostic === "string") {
      const diagnostic = JSON.parse(details.diagnostic) as Record<
        string,
        unknown
      >;
      // Only Cloud-authored diagnostics are read; a Service-authored one is a
      // local diagnostic and never influences the public category.
      if (
        diagnostic.component === "cloud" &&
        typeof diagnostic.stage === "string"
      ) {
        diagnosticStage = diagnostic.stage;
      }
    }
  } catch {
    // Malformed error_json carries no usable evidence.
  }
  return { diagnosticStage, revocationObservedStatus };
}

export function deriveExecutionPhase(
  evidence: ExecutionAssignmentEvidence,
): ExecutionPhase {
  const status = evidence.assignmentStatus;
  if (!status) {
    if (evidence.taskStatus === "completed") return "completed";
    if (evidence.taskStatus === "failed") return "failed";
    if (evidence.taskStatus === "cancelled") return "cancelled";
    return "submitted";
  }
  if (status === "completed") return "completed";
  if (status === "cancelled") return "cancelled";
  if (TERMINAL_ASSIGNMENT_STATUSES.has(status)) return "failed";
  if (status === "revocation_pending" || status === "reconciling") {
    return "uncertain";
  }
  if (status === "running") return "running";
  if (status === "created") return "waiting_for_service";
  if (status === "dispatched") return "delivering";
  if (status === "acknowledged") {
    if (
      evidence.startPermitIssuedAt ||
      (evidence.startupStage &&
        STARTING_STARTUP_STAGES.has(evidence.startupStage))
    ) {
      return "starting";
    }
    if (
      evidence.startPermitRequired ||
      (evidence.startupStage &&
        WAITING_STARTUP_STAGES.has(evidence.startupStage))
    ) {
      return "queued";
    }
    return "delivered";
  }
  return "submitted";
}

const PROFILE_CODES = new Set(["model_not_supported", "permission_denied"]);
const PROVIDER_START_CODES = new Set([
  "cli_not_found",
  "authentication_required",
  "unsupported_cli_version",
  "provider_unavailable",
  "quota_exhausted",
]);

/**
 * Category for a failed or unconfirmed step, derived from the assignment's
 * timeline (which phase it never left) and its canonical error code.
 */
export function deriveFailureCategory(
  evidence: ExecutionAssignmentEvidence,
): FailureCategory | null {
  const phase = deriveExecutionPhase(evidence);
  if (phase === "uncertain") return "state_uncertain";
  if (phase !== "failed") return null;
  const { diagnosticStage } = parseError(evidence.errorJson);
  const code = evidence.errorCode ?? "execution_failed";

  if (evidence.runningAt) return "execution_failed";
  if (code === "space_folder_exists") {
    return "space_folder_confirmation_required";
  }
  if (
    diagnosticStage === "workspace_disconnect" ||
    diagnosticStage === "workspace_lease" ||
    diagnosticStage === "gateway_dispatch"
  ) {
    return "service_unavailable";
  }
  if (!evidence.assignmentStatus) {
    // The step failed before any assignment was created (admission).
    return code === "worker_not_ready"
      ? "worker_unavailable"
      : "execution_failed";
  }
  if (!evidence.dispatchedAt) return "sync_incomplete";
  if (!evidence.acknowledgedAt) return "service_unavailable";
  if (PROFILE_CODES.has(code)) return "profile_incompatible";
  if (PROVIDER_START_CODES.has(code)) return "provider_start_failed";
  if (code === "worker_not_ready") return "worker_unavailable";
  const permitted =
    Boolean(evidence.startPermitIssuedAt) ||
    (evidence.startupStage !== null &&
      evidence.startupStage !== undefined &&
      STARTING_STARTUP_STAGES.has(evidence.startupStage));
  if (code === "timeout") {
    return permitted ? "startup_timeout" : "capacity_exceeded";
  }
  return permitted ? "provider_start_failed" : "worker_unavailable";
}

/**
 * Retry advice from evidence. Safe means the provider provably never started;
 * anything else (provider may have started, stop unconfirmed) needs an
 * explicit confirmation, and an unresolved stop cannot be retried at all.
 */
export function deriveRetryAdvice(
  evidence: ExecutionAssignmentEvidence,
): RetryAdvice | null {
  const phase = deriveExecutionPhase(evidence);
  if (phase === "uncertain") {
    return { allowed: false, requiresConfirmation: false };
  }
  if (phase !== "failed") return null;
  const { revocationObservedStatus } = parseError(evidence.errorJson);
  // The Service stopped before any provider work; the only thing the user
  // must decide is whether the existing folder may be used.
  if (evidence.errorCode === "space_folder_exists") {
    return { allowed: true, requiresConfirmation: true };
  }
  const providerMayHaveStarted =
    Boolean(evidence.runningAt) ||
    revocationObservedStatus === "running" ||
    Boolean(evidence.startPermitIssuedAt) ||
    evidence.startupStage === "engine_spawned" ||
    evidence.startupStage === "engine_initialized";
  return { allowed: true, requiresConfirmation: providerMayHaveStarted };
}

export function presentExecution(
  evidence: ExecutionAssignmentEvidence,
): ExecutionPresentation {
  const executionPhase = deriveExecutionPhase(evidence);
  const failureCategory = deriveFailureCategory(evidence);
  return {
    executionPhase,
    executionPhaseLabel: EXECUTION_PHASE_LABELS[executionPhase],
    executionPhaseDetail: EXECUTION_PHASE_DETAILS[executionPhase],
    failureCategory,
    failureCategoryMessage: failureCategory
      ? FAILURE_CATEGORY_MESSAGES[failureCategory]
      : null,
    retry: deriveRetryAdvice(evidence),
  };
}

/**
 * Request-level phase. A terminal Work Request status always wins, so a late
 * step still reading `running` can never flip a finished request back.
 * Otherwise the first step that has not completed describes the request.
 */
export function deriveRequestExecutionPhase(
  requestStatus: string,
  stepPhases: readonly ExecutionPhase[],
): ExecutionPhase {
  if (requestStatus === "completed") return "completed";
  if (requestStatus === "failed") return "failed";
  if (requestStatus === "cancelled") return "cancelled";
  const active = stepPhases.find((phase) => phase !== "completed");
  if (active) return active;
  return stepPhases.length > 0 ? "completed" : "submitted";
}
