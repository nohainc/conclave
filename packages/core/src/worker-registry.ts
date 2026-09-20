export type WorkerType =
  "model" | "agent" | "runtime" | "ci" | "tool" | "human";
export type WorkerAvailability = "available" | "busy" | "disabled" | "offline";
export type ExecutionEnvironment = "cloud" | "local" | "ci" | "human";

export interface WorkerCostMetadata {
  readonly currency: string;
  readonly estimatedCostMicrosPerAttempt: number | null;
  readonly inputMicrosPerMillionTokens: number | null;
  readonly outputMicrosPerMillionTokens: number | null;
}

export interface WorkerResource {
  readonly id: string;
  readonly name: string;
  readonly type: WorkerType;
  readonly provider: string;
  readonly adapterVersion: string;
  readonly capabilities: readonly string[];
  readonly roles: readonly string[];
  readonly permissions: readonly string[];
  readonly availability: WorkerAvailability;
  readonly cost: WorkerCostMetadata;
  readonly executionEnvironment: ExecutionEnvironment;
}

export interface WorkerRequirement {
  readonly capability: string;
  readonly role?: string;
  readonly permission?: string;
  readonly executionEnvironment?: ExecutionEnvironment;
  readonly maxEstimatedCostMicrosPerAttempt?: number;
}

export interface WorkerRegistry {
  upsert(worker: WorkerResource): void;
  list(): readonly WorkerResource[];
  resolve(requirement: WorkerRequirement): WorkerResource | null;
}

export class InMemoryWorkerRegistry implements WorkerRegistry {
  private readonly workers = new Map<string, WorkerResource>();

  upsert(worker: WorkerResource): void {
    if (worker.id.length === 0 || worker.provider.length === 0) {
      throw new Error("Worker id and provider are required");
    }
    this.workers.set(worker.id, worker);
  }

  list(): readonly WorkerResource[] {
    return [...this.workers.values()];
  }

  resolve(requirement: WorkerRequirement): WorkerResource | null {
    const matches = this.list()
      .filter((worker) => worker.availability === "available")
      .filter((worker) => worker.capabilities.includes(requirement.capability))
      .filter(
        (worker) =>
          requirement.role === undefined ||
          worker.roles.includes(requirement.role),
      )
      .filter(
        (worker) =>
          requirement.permission === undefined ||
          worker.permissions.includes(requirement.permission),
      )
      .filter(
        (worker) =>
          requirement.executionEnvironment === undefined ||
          worker.executionEnvironment === requirement.executionEnvironment,
      )
      .filter(
        (worker) =>
          requirement.maxEstimatedCostMicrosPerAttempt === undefined ||
          (worker.cost.estimatedCostMicrosPerAttempt !== null &&
            worker.cost.estimatedCostMicrosPerAttempt <=
              requirement.maxEstimatedCostMicrosPerAttempt),
      )
      .sort((left, right) => {
        const leftCost =
          left.cost.estimatedCostMicrosPerAttempt ?? Number.MAX_SAFE_INTEGER;
        const rightCost =
          right.cost.estimatedCostMicrosPerAttempt ?? Number.MAX_SAFE_INTEGER;
        return leftCost - rightCost || left.id.localeCompare(right.id);
      });

    return matches[0] ?? null;
  }
}
