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
  payload: { snapshot: { workerTypeId: "chatgpt" }, input: {} },
};

describe("Workspace Runtime protocol", () => {
  it("uses Workspace lifecycle message names", () => {
    expect(
      parseWorkspaceRuntimeMessage({ ...base, type: "workspace.hello" }).type,
    ).toBe("workspace.hello");
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
        payload: { snapshot: { workerTypeId: "chatgpt" }, input: {} },
      }).type,
    ).toBe("assignment.start");
  });

  it("accepts only canonical execution permissions in assignment snapshots", () => {
    const assignment = {
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
      payload: {
        snapshot: {
          workerTypeId: "chatgpt",
          permissions: ["repository:read", "repository:write"],
          permissionSnapshot: {
            permissions: ["repository:read", "repository:write"],
          },
        },
        input: {},
      },
    };
    expect(parseWorkspaceRuntimeMessage(assignment).type).toBe(
      "assignment.start",
    );
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...assignment,
        payload: {
          snapshot: {
            workerTypeId: "chatgpt",
            permissions: ["workspace:read"],
            permissionSnapshot: { permissions: ["workspace:read"] },
          },
          input: {},
        },
      }),
    ).toThrow();
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...assignment,
        payload: {
          snapshot: {
            workerTypeId: "chatgpt",
            permissions: ["repository:read"],
            permissionSnapshot: { permissions: ["repository:write"] },
          },
          input: {},
        },
      }),
    ).toThrow(/permission fields must match/);
  });

  it("rejects removed Checkout control-plane messages", () => {
    for (const type of [
      "checkout.provision",
      "checkout.status",
      "checkout.recover",
      "checkout.archive",
      "checkout.finalize",
    ]) {
      expect(() => parseWorkspaceRuntimeMessage({ ...base, type })).toThrow();
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
      workerTypeId: "chatgpt",
      activationState: "enabled",
      readinessState: "setup_required",
      readinessIssueCode: "setup_required",
      engineVersion: "1.0.0",
      profileDefinitionId: "chatgpt-codex",
      profileReleaseVersion: 1,
      providerToolName: "codex",
      providerToolVersion: null,
      capabilities: ["code"],
      localConcurrencyLimit: 1,
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
          workers: [{ ...worker, providerToolPath: "/local/only/codex" }],
          fullSnapshot: true,
        },
      }),
    ).toThrow();
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "worker.inventory",
        payload: {
          workers: [{ ...worker, providerToolName: "/Users/local/codex" }],
          fullSnapshot: true,
        },
      }),
    ).toThrow();
    expect(
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "worker.inventory",
        payload: {
          workers: [
            {
              ...worker,
              readinessState: "not_probed",
              readinessIssueCode: "probe_required",
            },
          ],
          fullSnapshot: true,
        },
      }).type,
    ).toBe("worker.inventory");
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...base,
        type: "worker.inventory",
        payload: {
          workers: [{ ...worker, readinessIssueCode: "api_key=secret" }],
          fullSnapshot: true,
        },
      }),
    ).toThrow();
    for (const obsoleteField of ["providerToolPath"]) {
      expect(() =>
        parseWorkspaceRuntimeMessage({
          ...base,
          type: "worker.inventory",
          payload: {
            workers: [{ ...worker, [obsoleteField]: "must-not-sync" }],
            fullSnapshot: true,
          },
        }),
      ).toThrow();
    }
    for (const providerCliName of ["codex", "antigravity"]) {
      expect(() =>
        parseWorkspaceRuntimeMessage({
          ...base,
          type: "worker.inventory",
          payload: {
            workers: [{ ...worker, workerTypeId: providerCliName }],
            fullSnapshot: true,
          },
        }),
      ).toThrow();
    }
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

  it("requires logical Worker types in Cloud assignment snapshots", () => {
    const assignment = {
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
      payload: { snapshot: { workerTypeId: "chatgpt" }, input: {} },
    };
    expect(parseWorkspaceRuntimeMessage(assignment).type).toBe(
      "assignment.start",
    );
    for (const providerCliName of ["codex", "antigravity"]) {
      expect(() =>
        parseWorkspaceRuntimeMessage({
          ...assignment,
          payload: { snapshot: { workerTypeId: providerCliName }, input: {} },
        }),
      ).toThrow();
    }
  });

  it("accepts only canonical assignment error codes", () => {
    const identity = {
      executionWorkspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      workerId: "worker-a",
      runId: "run-a",
      taskId: "task-a",
      attemptId: "attempt-a",
      assignmentId: "assignment-a",
      idempotencyKey: "idem-a",
    };
    const assignmentError = {
      ...base,
      ...identity,
      type: "assignment.error",
      payload: {
        status: "failed",
        error: {
          code: "permission_denied",
          message:
            "A local permission required for this assignment was denied.",
          retryable: false,
        },
      },
    };
    expect(parseWorkspaceRuntimeMessage(assignmentError).type).toBe(
      "assignment.error",
    );
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...assignmentError,
        payload: {
          ...assignmentError.payload,
          error: {
            ...assignmentError.payload.error,
            code: "tool_permission_denied",
          },
        },
      }),
    ).toThrow();
    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...assignmentError,
        payload: {
          ...assignmentError.payload,
          error: {
            ...assignmentError.payload.error,
            message: "provider stderr: secret diagnostic",
          },
        },
      }),
    ).toThrow(/canonical safe message/);
  });
});
