import { parseModelResult, type ModelResult } from "@conclave/protocol";

export * from "./worker-registry.js";
export * from "./worker-execution.js";
export * from "./execution-policy.js";
export * from "./read-only-roles.js";
export * from "./quality-presets.js";
export * from "./parallel-implementation.js";
export * from "./external-workers.js";
export * from "./worker-fallback.js";
export * from "./task-graph.js";
export * from "./verification.js";
export * from "./completion.js";

export const CORE_PROTOCOL_VERSION = "0.1";

export type GoalStatus =
  | "draft"
  | "ready"
  | "running"
  | "waiting"
  | "completed"
  | "failed"
  | "cancelled"
  | "superseded";

export interface GoalSummary {
  readonly id: string;
  readonly objective: string;
  readonly status: GoalStatus;
}

export function isTerminalGoalStatus(status: GoalStatus): boolean {
  return (
    status === "completed" ||
    status === "failed" ||
    status === "cancelled" ||
    status === "superseded"
  );
}

/**
 * Core's model-result admission boundary. Callers must provide untrusted data
 * as unknown; only the parsed result may be used for state transitions.
 */
export function admitModelResult(input: unknown): ModelResult {
  return parseModelResult(input);
}
