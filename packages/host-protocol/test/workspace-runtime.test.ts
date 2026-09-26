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

  it("accepts logical Workstream readiness without a local path", () => {
    expect(
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "workstream.status",
        payload: {
          projectId: "project-1",
          workstreamId: "workstream-1",
          workingDirectoryState: "ready",
        },
      }).type,
    ).toBe("workstream.status");
  });

  it("accepts only bounded safe Worker inventory projections", () => {
    const worker = {
      workerId: "worker-a",
      workerTypeId: "codex",
      name: "Codex Personal",
      status: "needs_attention",
      authStrategy: "browser_auth",
      defaultModel: null,
      allowedModels: [],
      capabilities: ["code"],
      localPermissionsSummary: ["workstream_filesystem"],
      localConcurrencyLimit: 1,
      adapterVersion: null,
      credentialStatus: "needs_authentication",
      revision: 1,
      createdAt: "2026-09-24T12:00:00.000Z",
      updatedAt: "2026-09-24T12:00:00.000Z",
      lastSeenAt: "2026-09-24T12:00:00.000Z",
    };
    expect(
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "worker.inventory",
        payload: { workers: [worker], fullSnapshot: true },
      }).type,
    ).toBe("worker.inventory");
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "worker.inventory",
        payload: {
          workers: [{ ...worker, apiKey: "never-sync-this" }],
          fullSnapshot: true,
        },
      }),
    ).toThrow();
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...base,
        protocolVersion: "5.0",
        type: "worker.inventory",
        payload: { workers: [worker], fullSnapshot: true },
      }),
    ).toThrow(/requires Workspace protocol 5.1/);
  });
});
