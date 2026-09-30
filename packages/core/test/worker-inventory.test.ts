import { describe, expect, it } from "vitest";
import {
  validateWorkspaceWorkerInventory,
  validateWorkspaceWorkerInventorySnapshot,
  type WorkspaceWorkerInventory,
} from "../src/worker-inventory.js";

function worker(
  workerId: string,
  workspaceId: string,
): WorkspaceWorkerInventory {
  return {
    workerId,
    workspaceId,
    ownerUserId: "owner",
    workerTypeId: "chatgpt",
    activationState: "enabled",
    readinessState: "ready",
    readinessIssueCode: null,
    workerRuntimeVersion: "2.0.0",
    providerToolName: "codex",
    providerToolVersion: "1.0.0",
    capabilities: ["code"],
    localConcurrencyLimit: 1,
    revision: 1,
    createdAt: "2026-09-26T00:00:00Z",
    updatedAt: "2026-09-26T00:00:00Z",
    lastSeenAt: "2026-09-26T00:00:00Z",
  };
}

describe("Workspace Worker inventory domain", () => {
  it("allows fixed-catalog slots with identical product types across Workspaces", () => {
    expect(() =>
      validateWorkspaceWorkerInventorySnapshot([
        worker("worker-a", "workspace-a"),
        worker("worker-b", "workspace-b"),
      ]),
    ).not.toThrow();
  });

  it("rejects duplicate Worker identities in one snapshot", () => {
    expect(() =>
      validateWorkspaceWorkerInventorySnapshot([
        worker("worker-a", "workspace-a"),
        worker("worker-a", "workspace-b"),
      ]),
    ).toThrow(/workerIds must be unique/);
  });

  it("enforces safe bounded concurrency, version, and capability metadata", () => {
    expect(() =>
      validateWorkspaceWorkerInventory({
        ...worker("worker-a", "workspace-a"),
        localConcurrencyLimit: 0,
      }),
    ).toThrow(/localConcurrencyLimit/);
    expect(() =>
      validateWorkspaceWorkerInventory({
        ...worker("worker-a", "workspace-a"),
        workerRuntimeVersion: "v".repeat(129),
      }),
    ).toThrow(/workerRuntimeVersion/);
    expect(() =>
      validateWorkspaceWorkerInventory({
        ...worker("worker-a", "workspace-a"),
        capabilities: ["code", "code"],
      }),
    ).toThrow(/capabilities must be unique/);
  });
});
