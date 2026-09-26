/**
 * Additive Architecture v7 Worker contracts. The v6 entities remain available
 * while persistence and runtime migration proceeds through the approved slice.
 */

import { DomainInvariantError } from "./entities.js";

export type V7WorkerStatus =
  "ready" | "needs_attention" | "disabled" | "offline" | "removed";

export type V7CredentialStatus =
  "not_required" | "ready" | "needs_authentication" | "expired" | "error";

export type V7AuthStrategy =
  "none" | "browser_auth" | "api_key" | "local_endpoint";
export type V7ModelSelectionMode = "fixed" | "allow_list" | "automatic";

/** Cloud-safe projection of one locally configured executable identity. */
export interface V7ConfiguredWorker {
  readonly id: string;
  readonly workspaceId: string;
  readonly ownerUserId: string;
  readonly name: string;
  readonly workerTypeId: string;
  readonly status: V7WorkerStatus;
  readonly authStrategy: V7AuthStrategy;
  readonly defaultModel: string | null;
  readonly allowedModels: readonly string[];
  readonly capabilities: readonly string[];
  readonly localPermissionsSummary: readonly string[];
  readonly localConcurrencyLimit: number;
  readonly adapterVersion: string | null;
  readonly credentialStatus: V7CredentialStatus;
  readonly lastSeenAt: string | null;
  readonly revision: number;
  readonly createdAt: string;
  readonly updatedAt: string;
}

/** Integration/adapter catalog entry. A model is never a Worker Type. */
export interface V7WorkerType {
  readonly id: string;
  readonly displayName: string;
  readonly publisher: string;
  readonly adapterProtocolVersion: string;
  readonly capabilities: readonly string[];
  readonly authStrategies: readonly V7AuthStrategy[];
  readonly modelSelectionMode: V7ModelSelectionMode;
  readonly supportedPlatforms: readonly string[];
  readonly permissions: readonly string[];
  readonly prerequisites: readonly string[];
  readonly currentRelease: string | null;
  readonly releaseChannel: string;
}

function required(value: string, field: string): void {
  if (value.trim().length === 0)
    throw new DomainInvariantError(`${field} is required`);
}

function unique(values: readonly string[], field: string): void {
  if (new Set(values).size !== values.length) {
    throw new DomainInvariantError(`${field} must be unique`);
  }
}

export function validateV7WorkerType(type: V7WorkerType): void {
  required(type.id, "WorkerType id");
  required(type.displayName, "WorkerType displayName");
  required(type.publisher, "WorkerType publisher");
  required(type.adapterProtocolVersion, "WorkerType adapterProtocolVersion");
  required(type.releaseChannel, "WorkerType releaseChannel");
  if (
    /^(?:gpt[- ]?\d|gemini[- ]?(?:pro|flash)|claude[- ]?(?:sonnet|opus|haiku))(?:$|[- .])/i.test(
      type.id,
    ) ||
    /^(?:gpt[- ]?\d|gemini[- ]?(?:pro|flash)|claude[- ]?(?:sonnet|opus|haiku))(?:$|[- .])/i.test(
      type.displayName,
    )
  ) {
    throw new DomainInvariantError(
      "WorkerType must identify an integration, not a model",
    );
  }
  unique(type.capabilities, "WorkerType capabilities");
  unique(type.authStrategies, "WorkerType authStrategies");
  unique(type.supportedPlatforms, "WorkerType supportedPlatforms");
  unique(type.permissions, "WorkerType permissions");
  unique(type.prerequisites, "WorkerType prerequisites");
}

export function validateV7ConfiguredWorker(
  worker: V7ConfiguredWorker,
  workerType?: V7WorkerType,
): void {
  required(worker.id, "ConfiguredWorker id");
  required(worker.workspaceId, "ConfiguredWorker workspaceId");
  required(worker.ownerUserId, "ConfiguredWorker ownerUserId");
  required(worker.name, "ConfiguredWorker name");
  required(worker.workerTypeId, "ConfiguredWorker workerTypeId");
  if (
    !Number.isInteger(worker.localConcurrencyLimit) ||
    worker.localConcurrencyLimit < 1
  ) {
    throw new DomainInvariantError(
      "ConfiguredWorker localConcurrencyLimit must be a positive integer",
    );
  }
  if (!Number.isSafeInteger(worker.revision) || worker.revision < 1) {
    throw new DomainInvariantError(
      "ConfiguredWorker revision must be a positive safe integer",
    );
  }
  unique(worker.allowedModels, "ConfiguredWorker allowedModels");
  unique(worker.capabilities, "ConfiguredWorker capabilities");
  unique(
    worker.localPermissionsSummary,
    "ConfiguredWorker localPermissionsSummary",
  );
  if (workerType) {
    validateV7WorkerType(workerType);
    if (worker.workerTypeId !== workerType.id) {
      throw new DomainInvariantError(
        "ConfiguredWorker workerTypeId does not match WorkerType id",
      );
    }
    if (!workerType.authStrategies.includes(worker.authStrategy)) {
      throw new DomainInvariantError(
        "ConfiguredWorker authStrategy is not supported by its WorkerType",
      );
    }
  }
}

/** IDs are immutable: updates deliberately cannot accept an `id` field. */
export function updateV7ConfiguredWorker(
  current: V7ConfiguredWorker,
  changes: Partial<
    Omit<
      V7ConfiguredWorker,
      "id" | "workspaceId" | "ownerUserId" | "createdAt" | "revision"
    >
  >,
): V7ConfiguredWorker {
  const updated: V7ConfiguredWorker = {
    ...current,
    ...changes,
    id: current.id,
    workspaceId: current.workspaceId,
    ownerUserId: current.ownerUserId,
    createdAt: current.createdAt,
    revision: current.revision + 1,
  };
  validateV7ConfiguredWorker(updated);
  return updated;
}

/** Names are unique case-insensitively within a Workspace, never globally. */
export function validateV7ConfiguredWorkers(
  workers: readonly V7ConfiguredWorker[],
): void {
  unique(
    workers.map((worker) => worker.id),
    "ConfiguredWorker ids",
  );
  const workspaceNames = workers.map(
    (worker) =>
      `${worker.workspaceId}\u0000${worker.name.trim().toLocaleLowerCase()}`,
  );
  unique(workspaceNames, "ConfiguredWorker Workspace/name pairs");
  workers.forEach((worker) => validateV7ConfiguredWorker(worker));
}
