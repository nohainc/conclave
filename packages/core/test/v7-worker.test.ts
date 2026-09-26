import { describe, expect, it } from "vitest";
import {
  validateV7ConfiguredWorkers,
  validateV7WorkerType,
  updateV7ConfiguredWorker,
  type V7ConfiguredWorker,
  type V7WorkerType,
} from "../src/v7-worker.js";

const workerType: V7WorkerType = {
  id: "codex",
  displayName: "Codex",
  publisher: "OpenAI",
  adapterProtocolVersion: "1",
  capabilities: ["code"],
  authStrategies: ["browser_auth"],
  modelSelectionMode: "allow_list",
  supportedPlatforms: ["macos"],
  permissions: ["workstream_filesystem"],
  prerequisites: ["codex-cli"],
  currentRelease: "1.2.0",
  releaseChannel: "stable",
};

function worker(
  id: string,
  workspaceId: string,
  name: string,
): V7ConfiguredWorker {
  return {
    id,
    workspaceId,
    ownerUserId: "owner",
    name,
    workerTypeId: workerType.id,
    status: "ready",
    authStrategy: "browser_auth",
    defaultModel: "provider-default",
    allowedModels: ["provider-default"],
    capabilities: ["code"],
    localPermissionsSummary: ["workstream_filesystem"],
    localConcurrencyLimit: 1,
    adapterVersion: "1.2.0",
    credentialStatus: "ready",
    lastSeenAt: null,
    revision: 1,
    createdAt: "2026-09-26T00:00:00Z",
    updatedAt: "2026-09-26T00:00:00Z",
  };
}

describe("Architecture v7 Worker contracts", () => {
  it("allows duplicate names across Workspaces and enforces case-insensitive local uniqueness", () => {
    expect(() =>
      validateV7ConfiguredWorkers([
        worker("w1", "ws1", "Personal"),
        worker("w2", "ws2", "Personal"),
      ]),
    ).not.toThrow();
    expect(() =>
      validateV7ConfiguredWorkers([
        worker("w1", "ws1", "Personal"),
        worker("w2", "ws1", "personal"),
      ]),
    ).toThrow(/Workspace\/name pairs/);
  });

  it("binds each Worker to one Workspace and keeps the Worker ID immutable on update", () => {
    const original = worker("immutable-id", "ws1", "Codex Personal");
    const updated = updateV7ConfiguredWorker(original, { name: "Codex Work" });
    expect(updated.id).toBe(original.id);
    expect(updated.workspaceId).toBe(original.workspaceId);
    expect(updated.revision).toBe(2);
  });

  it("models an integration separately from model configuration", () => {
    validateV7WorkerType(workerType);
    const configured = worker("w1", "ws1", "Codex");
    expect(configured.workerTypeId).toBe(workerType.id);
    expect(configured.defaultModel).not.toBe(workerType.id);
    expect(() =>
      validateV7WorkerType({ ...workerType, id: "gpt-" + "5" }),
    ).toThrow(/integration, not a model/);
  });
});
