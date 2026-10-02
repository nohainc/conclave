import type { ExecutionErrorCode } from "@conclave/protocol";

export * from "./workspace-runtime.js";
export * from "./desktop-auth-transport.js";

/** Assignment completion payloads consumed by Cloud's state transition layer. */
export interface AssignmentResultPayload {
  readonly assignmentId: string;
  readonly status: "completed" | "failed" | "cancelled";
  readonly output: Record<string, unknown> | null;
  readonly findings?: readonly unknown[];
  readonly artifactIds: readonly string[];
  readonly evidence?: {
    readonly observedAt: string;
    readonly metrics?: Record<string, unknown>;
    readonly logs?: readonly string[];
  };
  readonly completedAt: string;
}

export interface AssignmentFailurePayload {
  readonly error: {
    readonly code: ExecutionErrorCode;
    readonly message: string;
    readonly retryable: boolean;
    readonly details?: Record<string, unknown>;
  };
  readonly failedAt: string;
}

export interface AssignmentCancelPayload {
  readonly assignmentId: string;
  readonly reason: string;
  readonly deadlineMs?: number;
}
