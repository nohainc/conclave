import { describe, expect, it } from "vitest";
import {
  type ConfiguredWorker,
  type WorkerType,
  type WorkerWorkspaceBinding,
  canExecuteConfiguredWorker,
  deserializeConfiguredWorkerEntity,
  isWorkerWorkspaceBindingReady,
  revokeConfiguredWorker,
  serializeConfiguredWorkerEntity,
  validateConfiguredWorker,
  validateConfiguredWorkers,
  validateWorkerWorkspaceBinding,
  validateWorkerWorkspaceBindings,
} from "../src/index.js";

const workerType: WorkerType = {
  id: "worker-type-codex",
  displayName: "Codex",
  description: "Coding worker",
  publisher: "conclave",
  supportedRoles: ["research", "implementation"],
  supportedCapabilities: ["code_editing"],
  status: "active",
};

const worker: ConfiguredWorker = {
  id: "worker-personal",
  ownerUserId: "user-1",
  name: "Codex Personal",
  workerTypeId: workerType.id,
  status: "active",
  defaultModel: "codex-latest",
  config: { quality: "balanced" },
  concurrencyLimit: 2,
  costMetadata: { billingMode: "subscription", currency: "USD" },
  preferredRoles: ["implementation"],
  allowedRoles: ["research", "implementation"],
  createdAt: "2026-09-25T10:00:00.000Z",
  updatedAt: "2026-09-25T10:00:00.000Z",
};

const binding = (workspaceId: string): WorkerWorkspaceBinding => ({
  workerId: worker.id,
  workspaceId,
  enabled: true,
  desiredVersionPolicy: "stable",
  localReadiness: "ready",
  packageStatus: "ready",
  credentialStatus: "ready",
  permissionsStatus: "ready",
  lastSeen: "2026-09-25T10:01:00.000Z",
  updatedAt: "2026-09-25T10:01:00.000Z",
});

describe("EW-1 configured Worker domain", () => {
  it("serializes and restores Worker Type, Worker, and Workspace binding", () => {
    validateConfiguredWorker(worker, workerType);
    validateWorkerWorkspaceBinding(binding("workspace-a"), worker);
    const snapshot = {
      workerType,
      worker,
      binding: binding("workspace-a"),
    };
    expect(
      deserializeConfiguredWorkerEntity<typeof snapshot>(
        serializeConfiguredWorkerEntity(snapshot),
      ),
    ).toEqual(snapshot);
  });

  it("enforces Worker Type reference and owner/name uniqueness", () => {
    expect(() =>
      validateConfiguredWorker(worker, { ...workerType, id: "other" }),
    ).toThrow(/workerTypeId does not match/);
    expect(() =>
      validateConfiguredWorkers([worker, { ...worker, id: "worker-2" }]),
    ).toThrow(/owner\/name pairs/);
    expect(() =>
      validateConfiguredWorkers([
        worker,
        { ...worker, id: "worker-2", ownerUserId: "user-2" },
      ]),
    ).not.toThrow();
  });

  it("supports one Worker Type to many Workers and one Worker to many Workspaces", () => {
    const secondWorker = {
      ...worker,
      id: "worker-company",
      name: "Codex Company",
    };
    expect(() =>
      validateConfiguredWorker(secondWorker, workerType),
    ).not.toThrow();
    expect(() =>
      validateWorkerWorkspaceBindings(worker, [
        binding("workspace-a"),
        binding("workspace-b"),
      ]),
    ).not.toThrow();
  });

  it("requires a binding and aggregates package, credential, and permission readiness", () => {
    const ready = binding("workspace-a");
    expect(isWorkerWorkspaceBindingReady(ready)).toBe(true);
    expect(canExecuteConfiguredWorker(worker, "workspace-a", [ready])).toBe(
      true,
    );
    expect(
      canExecuteConfiguredWorker(worker, "workspace-missing", [ready]),
    ).toBe(false);
    expect(
      isWorkerWorkspaceBindingReady({
        ...ready,
        credentialStatus: "setup_required",
      }),
    ).toBe(false);
    expect(
      isWorkerWorkspaceBindingReady({ ...ready, packageStatus: "updating" }),
    ).toBe(false);
    expect(
      isWorkerWorkspaceBindingReady({ ...ready, permissionsStatus: "denied" }),
    ).toBe(false);
    expect(() =>
      validateWorkerWorkspaceBinding({
        ...ready,
        localReadiness: "ready",
        packageStatus: "failed",
      }),
    ).toThrow(/ready package/);
  });

  it("revoking a Worker disables all Workspace bindings", () => {
    const result = revokeConfiguredWorker(worker, [
      binding("workspace-a"),
      binding("workspace-b"),
    ]);
    expect(result.worker.status).toBe("revoked");
    expect(result.bindings).toHaveLength(2);
    expect(
      result.bindings.every(
        (item) => !item.enabled && item.localReadiness === "revoked",
      ),
    ).toBe(true);
    expect(
      canExecuteConfiguredWorker(result.worker, "workspace-a", result.bindings),
    ).toBe(false);
  });
});
