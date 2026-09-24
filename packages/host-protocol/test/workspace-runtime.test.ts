import { describe, expect, it } from "vitest";
import {
  parseWorkspaceRuntimeMessage,
  WORKSPACE_RUNTIME_PROTOCOL_NAME,
  WORKSPACE_RUNTIME_PROTOCOL_VERSION,
} from "../src/index.js";

const base = {
  protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
  protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
  messageId: "message-1",
  timestamp: "2026-09-24T12:00:00.000Z",
  payload: {},
};

describe("Workspace Runtime protocol", () => {
  it("uses workspace lifecycle message names", () => {
    expect(
      parseWorkspaceRuntimeMessage({ ...base, type: "workspace.hello" }).type,
    ).toBe("workspace.hello");
    expect(() =>
      parseWorkspaceRuntimeMessage({ ...base, type: "host.hello" }),
    ).toThrow();
  });

  it("requires both execution and runtime identity on assignments", () => {
    expect(() =>
      parseWorkspaceRuntimeMessage({ ...base, type: "assignment.start" }),
    ).toThrow(/executionWorkspaceId/);
    expect(
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "assignment.start",
        executionWorkspaceId: "workspace-a",
        workspaceRuntimeId: "runtime-a",
        workerId: "worker-a",
        runId: "run-a",
        taskId: "task-a",
        attemptId: "attempt-a",
        assignmentId: "assignment-a",
        idempotencyKey: "idem-a",
      }).type,
    ).toBe("assignment.start");
  });

  it("accepts checkout control-plane messages", () => {
    for (const type of [
      "checkout.provision",
      "checkout.status",
      "checkout.recover",
      "checkout.archive",
    ]) {
      expect(parseWorkspaceRuntimeMessage({ ...base, type }).type).toBe(type);
    }
  });
});
