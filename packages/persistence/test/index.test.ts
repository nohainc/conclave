import { describe, expect, it } from "vitest";
import { reconstructRun, type RunAggregateRows } from "../src/index.js";

const rows: RunAggregateRows = {
  goal: {
    id: "goal-1",
    projectId: "project-1",
    originalMessage: "Fix the scheduler",
    objective: "Fix the scheduler",
    constraints: [],
    completionCriteria: ["Tests pass"],
    verificationPolicy: {},
    status: "completed",
    createdAt: "2026-09-21T10:00:00.000Z",
    updatedAt: "2026-09-21T10:05:00.000Z",
  },
  run: {
    id: "run-1",
    goalId: "goal-1",
    parentRunId: null,
    policySnapshot: {},
    currentPhaseId: "phase-1",
    status: "succeeded",
    startedAt: "2026-09-21T10:00:00.000Z",
    finishedAt: "2026-09-21T10:05:00.000Z",
    createdAt: "2026-09-21T10:00:00.000Z",
    updatedAt: "2026-09-21T10:05:00.000Z",
  },
  phases: [],
  tasks: [],
  dependencies: [],
  attempts: [],
  modelCalls: [],
  findings: [],
  verifications: [],
  artifacts: [],
  events: [
    {
      runId: "run-1",
      sequence: 2,
      id: "event-2",
      eventType: "RunCompleted",
      entityType: "run",
      entityId: "run-1",
      correlationId: "corr-1",
      payload: { status: "succeeded" },
      occurredAt: "2026-09-21T10:05:00.000Z",
    },
    {
      runId: "run-1",
      sequence: 1,
      id: "event-1",
      eventType: "RunStarted",
      entityType: "run",
      entityId: "run-1",
      correlationId: "corr-1",
      payload: { status: "active" },
      occurredAt: "2026-09-21T10:00:00.000Z",
    },
  ],
  usage: [],
};

describe("run persistence reconstruction", () => {
  it("reconstructs a complete goal/run aggregate from persisted rows and events", () => {
    const reconstructed = reconstructRun(rows);

    expect(reconstructed.goal.objective).toBe("Fix the scheduler");
    expect(reconstructed.run.status).toBe("succeeded");
    expect(reconstructed.eventSequence).toEqual([1, 2]);
    expect(reconstructed.events[0]?.eventType).toBe("RunStarted");
  });

  it("rejects a missing event sequence", () => {
    expect(() =>
      reconstructRun({ ...rows, events: [rows.events[0]!] }),
    ).toThrow("Run events must be contiguous");
  });

  it("rejects an event belonging to another run", () => {
    expect(() =>
      reconstructRun({
        ...rows,
        events: [{ ...rows.events[0]!, runId: "run-other", sequence: 1 }],
      }),
    ).toThrow("Run events must be contiguous");
  });
});
