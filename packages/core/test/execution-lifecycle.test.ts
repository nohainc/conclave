import { describe, expect, it } from "vitest";
import {
  canTransitionAssignment,
  canTransitionAttempt,
  canTransitionRun,
  canTransitionTask,
  canTransitionWorkRequest,
  isTerminalAssignmentStatus,
} from "../src/index.js";

describe("execution lifecycle transitions", () => {
  it("does not make dispatch or acceptance equivalent to running", () => {
    expect(canTransitionAssignment("created", "running")).toBe(false);
    expect(canTransitionAssignment("dispatched", "running")).toBe(false);
    expect(canTransitionAssignment("acknowledged", "running")).toBe(true);
  });

  it("makes assignment outcomes terminal and monotonic", () => {
    expect(isTerminalAssignmentStatus("completed")).toBe(true);
    expect(canTransitionAssignment("completed", "running")).toBe(false);
    expect(canTransitionAssignment("failed", "completed")).toBe(false);
    expect(canTransitionAssignment("running", "failed")).toBe(true);
  });

  it("gives each attempt the same fenced monotonic lifecycle", () => {
    expect(canTransitionAttempt("acknowledged", "running")).toBe(true);
    expect(canTransitionAttempt("running", "timed_out")).toBe(true);
    expect(canTransitionAttempt("completed", "running")).toBe(false);
  });

  it("defines legal task, run and Work Request convergence transitions", () => {
    expect(canTransitionTask("queued", "running")).toBe(true);
    expect(canTransitionTask("completed", "running")).toBe(false);
    expect(canTransitionRun("created", "running")).toBe(true);
    expect(canTransitionRun("completed", "failed")).toBe(false);
    expect(canTransitionWorkRequest("failed", "queued")).toBe(true);
    expect(canTransitionWorkRequest("cancelled", "queued")).toBe(false);
  });
});

