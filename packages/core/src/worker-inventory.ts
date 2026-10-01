import { DomainInvariantError } from "./entities.js";

export type WorkerActivationState = "enabled" | "disabled";
export type WorkerReadinessState =
  | "not_probed"
  | "ready"
  | "setup_required"
  | "sign_in_required"
  | "worker_runtime_unavailable"
  | "test_failed";

export const WORKER_INPUT_CAPABILITIES = [
  "text",
  "image",
  "audio",
  "video",
  "local_file",
] as const;
export type WorkerInputCapability = (typeof WORKER_INPUT_CAPABILITIES)[number];

/** Cloud-safe projection of a Workspace-owned fixed-catalog Worker slot. */
export interface WorkspaceWorkerInventory {
  readonly workerId: string;
  readonly workspaceId: string;
  readonly ownerUserId: string;
  readonly workerTypeId: string;
  readonly activationState: WorkerActivationState;
  readonly readinessState: WorkerReadinessState;
  readonly readinessIssueCode: string | null;
  readonly workerRuntimeVersion: string | null;
  readonly providerToolName: string | null;
  readonly providerToolVersion: string | null;
  readonly capabilities: readonly string[];
  readonly inputCapabilities: readonly WorkerInputCapability[];
  readonly localConcurrencyLimit: number;
  readonly revision: number;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly lastSeenAt: string;
}

function required(value: string, field: string): void {
  if (value.trim().length === 0) {
    throw new DomainInvariantError(`${field} is required`);
  }
}

function optionalText(value: string | null, field: string, maxLength: number) {
  if (
    value !== null &&
    (value.trim().length === 0 || value.length > maxLength)
  ) {
    throw new DomainInvariantError(`${field} must be null or bounded text`);
  }
}

function unique(values: readonly string[], field: string): void {
  if (new Set(values).size !== values.length) {
    throw new DomainInvariantError(`${field} must be unique`);
  }
}

export function validateWorkspaceWorkerInventory(
  worker: WorkspaceWorkerInventory,
): void {
  required(worker.workerId, "WorkerInventory workerId");
  required(worker.workspaceId, "WorkerInventory workspaceId");
  required(worker.ownerUserId, "WorkerInventory ownerUserId");
  required(worker.workerTypeId, "WorkerInventory workerTypeId");
  if (!(["enabled", "disabled"] as const).includes(worker.activationState)) {
    throw new DomainInvariantError(
      "WorkerInventory activationState is invalid",
    );
  }
  if (
    !(
      [
        "not_probed",
        "ready",
        "setup_required",
        "sign_in_required",
        "worker_runtime_unavailable",
        "test_failed",
      ] as const
    ).includes(worker.readinessState)
  ) {
    throw new DomainInvariantError("WorkerInventory readinessState is invalid");
  }
  if (
    !Number.isInteger(worker.localConcurrencyLimit) ||
    worker.localConcurrencyLimit < 1 ||
    worker.localConcurrencyLimit > 1024
  ) {
    throw new DomainInvariantError(
      "WorkerInventory localConcurrencyLimit must be between 1 and 1024",
    );
  }
  if (!Number.isSafeInteger(worker.revision) || worker.revision < 1) {
    throw new DomainInvariantError(
      "WorkerInventory revision must be a positive safe integer",
    );
  }
  optionalText(worker.readinessIssueCode, "readinessIssueCode", 128);
  optionalText(worker.workerRuntimeVersion, "workerRuntimeVersion", 128);
  optionalText(worker.providerToolName, "providerToolName", 128);
  optionalText(worker.providerToolVersion, "providerToolVersion", 128);
  unique(worker.capabilities, "WorkerInventory capabilities");
  unique(worker.inputCapabilities, "WorkerInventory inputCapabilities");
  if (
    worker.inputCapabilities.some(
      (capability) =>
        !(WORKER_INPUT_CAPABILITIES as readonly string[]).includes(capability),
    )
  ) {
    throw new DomainInvariantError(
      "WorkerInventory inputCapabilities contains an unsupported value",
    );
  }
  if (
    worker.inputCapabilities.some(
      (capability) => !worker.capabilities.includes(capability),
    )
  ) {
    throw new DomainInvariantError(
      "WorkerInventory inputCapabilities must be declared in capabilities",
    );
  }
  for (const [field, value] of [
    ["createdAt", worker.createdAt],
    ["updatedAt", worker.updatedAt],
    ["lastSeenAt", worker.lastSeenAt],
  ] as const) {
    if (!Number.isFinite(Date.parse(value))) {
      throw new DomainInvariantError(`WorkerInventory ${field} is invalid`);
    }
  }
}

export function validateWorkspaceWorkerInventorySnapshot(
  workers: readonly WorkspaceWorkerInventory[],
): void {
  if (workers.length > 500) {
    throw new DomainInvariantError(
      "WorkerInventory snapshot exceeds 500 slots",
    );
  }
  unique(
    workers.map((worker) => worker.workerId),
    "WorkerInventory workerIds",
  );
  workers.forEach(validateWorkspaceWorkerInventory);
}
