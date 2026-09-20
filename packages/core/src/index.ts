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
