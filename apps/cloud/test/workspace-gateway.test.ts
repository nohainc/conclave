import { describe, expect, it } from "vitest";
import {
  isCurrentWorkspaceSocket,
  isWorkspaceRuntimeAuthorized,
  normalizeWorkspaceWorkerInstallationStatus,
  workspaceAssignmentContextMatches,
} from "../src/workspace-gateway.js";

describe("Workspace runtime Gateway", () => {
  it("accepts only the runtime credential for one execution Workspace", async () => {
    const db = {
      prepare(query: string) {
        return {
          bind(runtimeId: string, tokenHash: string) {
            return {
              first: async () =>
                query.includes("credential_token_hash") &&
                runtimeId === "runtime-a" &&
                tokenHash === "hash-a"
                  ? { executionWorkspaceId: "workspace-a" }
                  : null,
            };
          },
        };
      },
    } as never;

    await expect(
      isWorkspaceRuntimeAuthorized(db, "runtime-a", "hash-a"),
    ).resolves.toEqual({ executionWorkspaceId: "workspace-a" });
    await expect(
      isWorkspaceRuntimeAuthorized(db, "runtime-a", "wrong-token"),
    ).resolves.toBeNull();
    await expect(
      isWorkspaceRuntimeAuthorized(db, "runtime-revoked", "hash-a"),
    ).resolves.toBeNull();
  });

  it("fences stale socket close events after reconnect", () => {
    const current = {} as WebSocket;
    const stale = {} as WebSocket;
    expect(isCurrentWorkspaceSocket(current, "new", current, "new")).toBe(true);
    expect(isCurrentWorkspaceSocket(current, "new", stale, "old")).toBe(false);
  });

  it("rejects assignment correlation for another Workspace runtime", () => {
    const row = {
      id: "assignment-1",
      execution_workspace_id: "workspace-a",
      runtime_identity_id: "runtime-a",
      worker_id: "worker-1",
      run_id: "run-1",
      task_id: "task-1",
      attempt_id: "attempt-1",
      idempotency_key: "idem-1",
    };
    const message = {
      executionWorkspaceId: "workspace-a",
      workspaceRuntimeId: "runtime-a",
      workerId: "worker-1",
      runId: "run-1",
      taskId: "task-1",
      attemptId: "attempt-1",
      assignmentId: "assignment-1",
      idempotencyKey: "idem-1",
    };
    expect(workspaceAssignmentContextMatches(message, row)).toBe(true);
    expect(
      workspaceAssignmentContextMatches(
        { ...message, workspaceRuntimeId: "runtime-b" },
        row,
      ),
    ).toBe(false);
    expect(
      workspaceAssignmentContextMatches(
        { ...message, executionWorkspaceId: "workspace-b" },
        row,
      ),
    ).toBe(false);
  });

  it("normalizes runtime Worker health without allowing it to change desired state", () => {
    expect(normalizeWorkspaceWorkerInstallationStatus("ready")).toBe("ready");
    expect(normalizeWorkspaceWorkerInstallationStatus("downloading")).toBe(
      "installing",
    );
    expect(normalizeWorkspaceWorkerInstallationStatus("updating")).toBe(
      "updating",
    );
    expect(normalizeWorkspaceWorkerInstallationStatus("unknown")).toBe(
      "failed",
    );
  });
});
