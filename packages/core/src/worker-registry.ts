export type WorkerType =
  "model" | "agent" | "runtime" | "ci" | "tool" | "human";
export type WorkerAvailability =
  "available" | "busy" | "disabled" | "offline" | "draining";
export type ExecutionEnvironment = "cloud" | "local" | "ci" | "human";
export type ConnectionTransport =
  | "provider_api"
  | "local_agent"
  | "remote_agent"
  | "local_model"
  | "web_app"
  | "manual";
export type ConnectionAuthMode =
  | "api_key"
  | "subscription_session"
  | "oauth"
  | "service_identity"
  | "local_session"
  | "none"
  | "manual";
export type ConnectionBillingMode =
  "api_metered" | "subscription" | "local_compute" | "external" | "manual";

export interface WorkerCostMetadata {
  readonly currency?: string;
  readonly estimatedCostMicrosPerAttempt: number | null;
  readonly inputMicrosPerMillionTokens?: number | null;
  readonly outputMicrosPerMillionTokens?: number | null;
  readonly [key: string]: unknown;
}

export interface ConnectionResource {
  readonly id: string;
  readonly name: string;
  readonly transport: ConnectionTransport;
  readonly provider: string | null;
  readonly adapterVersion: string;
  readonly authMode: ConnectionAuthMode;
  readonly billingMode: ConnectionBillingMode;
  readonly cost: WorkerCostMetadata;
  readonly executionEnvironment: ExecutionEnvironment;
  readonly availability: WorkerAvailability;
}

export interface WorkerResource {
  readonly id: string;
  readonly name: string;
  readonly type: WorkerType;
  readonly capabilities: readonly string[];
  readonly roles: readonly string[];
  readonly permissions: readonly string[];
  readonly independenceKey: string;
  readonly connectionIds: readonly string[];
  readonly availability: WorkerAvailability;
}

export interface WorkerRequirement {
  readonly capability: string;
  readonly role?: string;
  readonly permission?: string;
  readonly executionEnvironment?: ExecutionEnvironment;
  readonly maxEstimatedCostMicrosPerAttempt?: number;
}

export interface WorkerBinding {
  readonly worker: WorkerResource;
  readonly connection: ConnectionResource;
}

export interface WorkerRegistry {
  upsert(
    worker: WorkerResource,
    connections?: readonly ConnectionResource[],
  ): void;
  list(): readonly WorkerBinding[];
  resolve(requirement: WorkerRequirement): WorkerBinding | null;
}

export class InMemoryWorkerRegistry implements WorkerRegistry {
  private readonly workers = new Map<string, WorkerResource>();
  private readonly connections = new Map<string, ConnectionResource>();

  upsert(
    worker: WorkerResource,
    connections: readonly ConnectionResource[] = [],
  ): void {
    if (worker.id.length === 0 || worker.connectionIds.length === 0) {
      throw new Error("Worker id and at least one connection are required");
    }
    this.workers.set(worker.id, worker);
    for (const connection of connections)
      this.connections.set(connection.id, connection);
  }

  list(): readonly WorkerBinding[] {
    return [...this.workers.values()].flatMap((worker) =>
      worker.connectionIds.flatMap((connectionId) => {
        const connection = this.connections.get(connectionId);
        return connection ? [{ worker, connection }] : [];
      }),
    );
  }

  resolve(requirement: WorkerRequirement): WorkerBinding | null {
    const matches = this.list()
      .filter(
        ({ worker, connection }) =>
          worker.availability === "available" &&
          connection.availability === "available",
      )
      .filter(({ worker }) =>
        worker.capabilities.includes(requirement.capability),
      )
      .filter(
        ({ worker }) =>
          requirement.role === undefined ||
          worker.roles.includes(requirement.role),
      )
      .filter(
        ({ worker }) =>
          requirement.permission === undefined ||
          worker.permissions.includes(requirement.permission),
      )
      .filter(
        ({ connection }) =>
          requirement.executionEnvironment === undefined ||
          connection.executionEnvironment === requirement.executionEnvironment,
      )
      .filter(
        ({ connection }) =>
          requirement.maxEstimatedCostMicrosPerAttempt === undefined ||
          (connection.cost.estimatedCostMicrosPerAttempt !== null &&
            connection.cost.estimatedCostMicrosPerAttempt <=
              requirement.maxEstimatedCostMicrosPerAttempt),
      )
      .sort((left, right) => {
        const leftCost =
          left.connection.cost.estimatedCostMicrosPerAttempt ??
          Number.MAX_SAFE_INTEGER;
        const rightCost =
          right.connection.cost.estimatedCostMicrosPerAttempt ??
          Number.MAX_SAFE_INTEGER;
        return (
          leftCost - rightCost ||
          left.worker.id.localeCompare(right.worker.id) ||
          left.connection.id.localeCompare(right.connection.id)
        );
      });

    return matches[0] ?? null;
  }
}
