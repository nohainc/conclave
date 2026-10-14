import { describe, expect, it } from "vitest";
import {
  ASSIGNMENT_LIFECYCLE_STATUSES,
  ASSIGNMENT_TERMINAL_STATUSES,
  assignmentSourceStatuses,
  assignmentStatusForEvidence,
  canTransitionAssignment,
  canTransitionAttempt,
  canTransitionRun,
  canTransitionTask,
  canTransitionWorkRequest,
  isTerminalAssignmentStatus,
} from "../src/index.js";

describe("execution lifecycle transitions", () => {
  it("does not make dispatch or acceptance equivalent to running", () => {
    // Dispatch and admission never imply the provider started...
    expect(assignmentStatusForEvidence("delivery")).toBe("dispatched");
    expect(assignmentStatusForEvidence("admission")).toBe("acknowledged");
    expect(canTransitionAssignment("acknowledged", "running")).toBe(true);
  });

  it("lets later evidence skip earlier milestones but never go backward", () => {
    // ...but provider-start evidence proves admission, so it may arrive first.
    expect(canTransitionAssignment("created", "running")).toBe(true);
    expect(canTransitionAssignment("dispatched", "running")).toBe(true);
    expect(canTransitionAssignment("running", "acknowledged")).toBe(false);
    expect(canTransitionAssignment("running", "dispatched")).toBe(false);
    expect(canTransitionAssignment("acknowledged", "dispatched")).toBe(false);
    expect(canTransitionAssignment("acknowledged", "created")).toBe(false);
  });

  it("derives conditional-update source sets from the transition table", () => {
    expect(assignmentSourceStatuses("acknowledged")).toEqual([
      "created",
      "dispatched",
    ]);
    expect(assignmentSourceStatuses("running")).toEqual([
      "created",
      "dispatched",
      "acknowledged",
    ]);
    expect(assignmentSourceStatuses("completed")).toEqual([
      "created",
      "dispatched",
      "acknowledged",
      "running",
    ]);
    // Same-status replays match no row, so they cannot bump updated_at.
    for (const status of ASSIGNMENT_LIFECYCLE_STATUSES) {
      expect(assignmentSourceStatuses(status)).not.toContain(status);
    }
    // Terminal statuses are never a source.
    for (const target of ASSIGNMENT_LIFECYCLE_STATUSES) {
      for (const source of assignmentSourceStatuses(target)) {
        expect(ASSIGNMENT_TERMINAL_STATUSES).not.toContain(source);
      }
    }
    expect(assignmentSourceStatuses("lost")).toEqual(["running"]);
  });

  it("is acyclic: no sequence of legal transitions returns to an earlier status", () => {
    const rank = (status: (typeof ASSIGNMENT_LIFECYCLE_STATUSES)[number]) =>
      ASSIGNMENT_LIFECYCLE_STATUSES.indexOf(status);
    for (const from of ASSIGNMENT_LIFECYCLE_STATUSES) {
      for (const to of ASSIGNMENT_LIFECYCLE_STATUSES) {
        if (from !== to && canTransitionAssignment(from, to)) {
          expect(rank(to)).toBeGreaterThan(rank(from));
        }
      }
    }
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
