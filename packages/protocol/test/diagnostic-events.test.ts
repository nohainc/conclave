import { describe, expect, it } from "vitest";
import {
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
});
