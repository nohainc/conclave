import { describe, expect, it } from "vitest";
import {
  ALL_TRACE_STAGES,
  TRACE_STAGES,
  traceStageNumber,
  EXECUTION_TRACE_STAGES,
  createDiagnosticEvent,
  parseDiagnosticEvent,
} from "../src/index.js";

describe("execution diagnostics", () => {
  it("defines one ordered cross-component trace", () => {
    expect(EXECUTION_TRACE_STAGES).toEqual([
      "dispatch",
      "accepted",
      "slot_reservation",
      "engine_startup",
      "provider_execution",
      "activity_forwarding",
      "terminal_recorded",
      "terminal_acknowledgement",
    ]);
  });

  it("round-trips bounded correlated diagnostics", () => {
    const event = createDiagnosticEvent({
      assignmentId: "assignment-1",
      attemptId: "attempt-1",
      workspaceId: "workspace-1",
      workspaceRuntimeId: "runtime-1",
      workerId: "worker-1",
      component: "workspace_service",
      operation: "assignment",
      stage: "slot_reservation",
      severity: "info",
      retryable: false,
      context: { status: "reserved" },
    });
    expect(parseDiagnosticEvent(event)).toEqual(event);
  });

  it("numbers the twelve latency stages T1-T12 in order", () => {
    expect(TRACE_STAGES).toHaveLength(12);
    expect(traceStageNumber("web_submitted")).toBe(1);
    expect(traceStageNumber("provider_started")).toBe(10);
    expect(traceStageNumber("web_received")).toBe(12);
    expect(traceStageNumber("workflow_observed_terminal")).toBeUndefined();
    expect(new Set(ALL_TRACE_STAGES).size).toBe(ALL_TRACE_STAGES.length);
  });

  it("accepts local startup milestones without renumbering T1-T12", () => {
    for (const stage of [
      "worker_resolved",
      "profile_ready",
      "waiting_for_space",
      "queued_for_slot",
      "engine_initialized",
    ]) {
      expect(ALL_TRACE_STAGES).toContain(stage);
      expect(traceStageNumber(stage)).toBeUndefined();
    }
    expect(TRACE_STAGES).toHaveLength(12);
    const event = createDiagnosticEvent({
      assignmentId: "assignment-1",
      component: "workspace_service",
      operation: "assignment",
      stage: "trace",
      severity: "info",
      retryable: false,
      context: {
        traceStage: "queued_for_slot",
        queuePosition: 2,
        slotLimit: 1,
        activeAssignments: 1,
        waitingForSession: false,
        queueWaitTimeoutMs: 120000,
      } as never,
    });
    expect(parseDiagnosticEvent(event)).toEqual(event);
  });

  it("carries bounded timing context and rejects unknown stages", () => {
    const event = createDiagnosticEvent({
      assignmentId: "assignment-1",
      component: "workspace_service",
      operation: "assignment",
      stage: "trace",
      severity: "info",
      retryable: false,
      context: {
        traceStage: "service_received",
        monotonicMs: 1204,
        clockOffsetMs: -37,
        clockRttMs: 41,
        transport: "websocket",
        syncState: "ready",
        localQueueLength: 0,
        activeAssignments: 1,
      },
    });
    expect(parseDiagnosticEvent(event)).toEqual(event);
    expect(() =>
      createDiagnosticEvent({
        component: "cloud",
        operation: "assignment",
        stage: "trace",
        severity: "info",
        retryable: false,
        context: { traceStage: "bogus" as never },
      }),
    ).toThrow();
  });
});
