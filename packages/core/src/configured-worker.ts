/**
 * EW-1 configured Worker domain.
 *
 * Worker Types are catalog/infrastructure definitions. Configured Workers are
 * user-owned execution identities, and bindings describe their per-Workspace
 * runtime state. Credential metadata remains opaque and local-secret-safe.
 */

import { DomainInvariantError } from "./entities.js";

export type WorkerTypeStatus = "active" | "deprecated" | "revoked";

export interface WorkerType {
  readonly id: string;
  readonly displayName: string;
  readonly description: string;
  readonly publisher: string;
  readonly supportedRoles: readonly string[];
  readonly supportedCapabilities: readonly string[];
  readonly status: WorkerTypeStatus;
}

export type ConfiguredWorkerStatus = "active" | "disabled" | "revoked";

export interface ConfiguredWorkerCostMetadata {
  readonly billingMode?:
    | "api_metered"
    | "subscription"
    | "local_compute"
    | "external"
    | "manual"
    | "free";
  readonly currency?: string;
  readonly estimatedCostMicrosPerAttempt?: number | null;
  readonly inputMicrosPerMillionTokens?: number | null;
  readonly outputMicrosPerMillionTokens?: number | null;
}

/** A user-owned configured AI/tool identity, distinct from its Worker Type. */
export interface ConfiguredWorker {
  readonly id: string;
  readonly ownerUserId: string;
  readonly name: string;
  readonly workerTypeId: string;
  readonly status: ConfiguredWorkerStatus;
  readonly defaultModel: string | null;
  readonly config: Readonly<Record<string, unknown>>;
  readonly concurrencyLimit: number;
  readonly costMetadata: ConfiguredWorkerCostMetadata | null;
  readonly preferredRoles?: readonly string[];
  readonly allowedRoles?: readonly string[];
  readonly createdAt: string;
  readonly updatedAt: string;
}

export type WorkerBindingReadiness =
  "unknown" | "setup_required" | "ready" | "degraded" | "failed" | "revoked";
export type WorkerPackageStatus =
  "absent" | "installing" | "ready" | "updating" | "failed";
export type WorkerCredentialStatus =
  "unknown" | "setup_required" | "ready" | "expired" | "error";
export type WorkerPermissionsStatus =
  "unknown" | "checking" | "ready" | "denied" | "error";

/** Per-Workspace package, permission, and credential readiness for a Worker. */
export interface WorkerWorkspaceBinding {
  readonly workerId: string;
  readonly workspaceId: string;
  readonly enabled: boolean;
  readonly desiredVersionPolicy: string;
  readonly localReadiness: WorkerBindingReadiness;
  readonly packageStatus: WorkerPackageStatus;
  readonly credentialStatus: WorkerCredentialStatus;
  readonly permissionsStatus: WorkerPermissionsStatus;
  readonly lastSeen: string | null;
  readonly updatedAt: string;
}

export type CredentialAuthType =
  "none" | "api_key" | "oauth" | "session_token" | "local";
export type CredentialSharingPolicy = "private_only" | "explicit_project";
export type CredentialState =
  "setup_required" | "ready" | "expired" | "error" | "revoked";

/**
 * Internal credential metadata only. `localSecretRef` is an opaque reference
 * into a Workspace secure store; raw credential material is never represented.
 */
export interface WorkerCredentialMetadata {
  readonly id: string;
  readonly workerId: string;
  readonly ownerUserId: string;
  readonly authType: CredentialAuthType;
  readonly sharingPolicy: CredentialSharingPolicy;
  readonly providerMetadata: Readonly<Record<string, unknown>>;
  readonly localSecretRef: string | null;
  readonly stateByWorkspace: Readonly<Record<string, CredentialState>>;
}

function required(value: string, field: string): void {
  if (!value || value.trim().length === 0) {
    throw new DomainInvariantError(`${field} is required`);
  }
}

function positiveInteger(value: number, field: string): void {
  if (!Number.isInteger(value) || value <= 0) {
    throw new DomainInvariantError(`${field} must be a positive integer`);
  }
}

function unique(values: readonly string[], field: string): void {
  if (new Set(values).size !== values.length) {
    throw new DomainInvariantError(`${field} must be unique`);
  }
}

export function validateWorkerType(workerType: WorkerType): void {
  required(workerType.id, "WorkerType id");
  required(workerType.displayName, "WorkerType displayName");
  required(workerType.publisher, "WorkerType publisher");
  if (!workerType.status) {
    throw new DomainInvariantError("WorkerType status is required");
  }
}

/** Validates a Worker independently, or against the referenced catalog Type. */
export function validateConfiguredWorker(
  worker: ConfiguredWorker,
  workerType?: WorkerType,
): void {
  required(worker.id, "ConfiguredWorker id");
  required(worker.ownerUserId, "ConfiguredWorker ownerUserId");
  required(worker.name, "ConfiguredWorker name");
  required(worker.workerTypeId, "ConfiguredWorker workerTypeId");
  if (!worker.status) {
    throw new DomainInvariantError("ConfiguredWorker status is required");
  }
  positiveInteger(worker.concurrencyLimit, "ConfiguredWorker concurrencyLimit");
  if (workerType) {
    validateWorkerType(workerType);
    if (worker.workerTypeId !== workerType.id) {
      throw new DomainInvariantError(
        "ConfiguredWorker workerTypeId does not match WorkerType id",
      );
    }
  }
  unique(worker.preferredRoles ?? [], "ConfiguredWorker preferredRoles");
  unique(worker.allowedRoles ?? [], "ConfiguredWorker allowedRoles");
}

/** Enforces IDs and owner/name uniqueness for a user's configured Workers. */
export function validateConfiguredWorkers(
  workers: readonly ConfiguredWorker[],
): void {
  unique(
    workers.map((worker) => worker.id),
    "ConfiguredWorker ids",
  );
  const ownerNames = workers.map(
    (worker) =>
      `${worker.ownerUserId}\u0000${worker.name.trim().toLocaleLowerCase()}`,
  );
  unique(ownerNames, "ConfiguredWorker owner/name pairs");
  for (const worker of workers) validateConfiguredWorker(worker);
}

export function validateWorkerWorkspaceBinding(
  binding: WorkerWorkspaceBinding,
  worker?: ConfiguredWorker,
): void {
  required(binding.workerId, "WorkerWorkspaceBinding workerId");
  required(binding.workspaceId, "WorkerWorkspaceBinding workspaceId");
  required(
    binding.desiredVersionPolicy,
    "WorkerWorkspaceBinding desiredVersionPolicy",
  );
  if (worker && binding.workerId !== worker.id) {
    throw new DomainInvariantError(
      "WorkerWorkspaceBinding workerId does not match ConfiguredWorker id",
    );
  }
  if (
    binding.localReadiness === "ready" &&
    !isWorkerWorkspaceBindingReady(binding)
  ) {
    throw new DomainInvariantError(
      "Ready WorkerWorkspaceBinding must have ready package, credential, and permissions",
    );
  }
}

export function validateWorkerWorkspaceBindings(
  worker: ConfiguredWorker,
  bindings: readonly WorkerWorkspaceBinding[],
): void {
  const workspaceIds = bindings.map((binding) => binding.workspaceId);
  unique(workspaceIds, "WorkerWorkspaceBinding workspaceIds");
  for (const binding of bindings) {
    validateWorkerWorkspaceBinding(binding, worker);
  }
}

/** Readiness is the conjunction of package, credential, and permission state. */
export function isWorkerWorkspaceBindingReady(
  binding: WorkerWorkspaceBinding,
): boolean {
  return (
    binding.enabled &&
    binding.localReadiness === "ready" &&
    binding.packageStatus === "ready" &&
    binding.credentialStatus === "ready" &&
    binding.permissionsStatus === "ready"
  );
}

/** Unbound or non-ready Workers cannot execute on a Workspace. */
export function canExecuteConfiguredWorker(
  worker: ConfiguredWorker,
  workspaceId: string,
  bindings: readonly WorkerWorkspaceBinding[],
): boolean {
  if (worker.status !== "active") return false;
  const binding = bindings.find(
    (candidate) =>
      candidate.workerId === worker.id && candidate.workspaceId === workspaceId,
  );
  return binding ? isWorkerWorkspaceBindingReady(binding) : false;
}

/** Revocation is explicit and disables every Workspace binding atomically. */
export function revokeConfiguredWorker(
  worker: ConfiguredWorker,
  bindings: readonly WorkerWorkspaceBinding[],
): { worker: ConfiguredWorker; bindings: readonly WorkerWorkspaceBinding[] } {
  validateConfiguredWorker(worker);
  validateWorkerWorkspaceBindings(worker, bindings);
  return {
    worker: { ...worker, status: "revoked" },
    bindings: bindings.map((binding) => ({
      ...binding,
      enabled: false,
      localReadiness: "revoked",
      updatedAt: worker.updatedAt,
    })),
  };
}

export function serializeConfiguredWorkerEntity<T extends object>(
  entity: T,
): string {
  return JSON.stringify(entity);
}

export function deserializeConfiguredWorkerEntity<T>(serialized: string): T {
  const value: unknown = JSON.parse(serialized);
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainInvariantError(
      "Serialized configured Worker entity must be an object",
    );
  }
  return value as T;
}
