import type {
  WorkerExecutionRequest,
  WorkerExecutionResult,
  WorkerExecutor,
  WorkerRegistry,
  WorkerRequirement,
} from "./index.js";

export type ReadOnlyRole = "researcher" | "architect" | "planner" | "reviewer";

const roleCapabilities: Record<ReadOnlyRole, string> = {
  researcher: "repository_research",
  architect: "architecture",
  planner: "planning",
  reviewer: "code_review",
};

const forbiddenPermissions = new Set([
  "repository_write",
  "shell_execute",
  "build_execute",
  "git_write",
  "runtime_write",
]);

export class ReadOnlyRoleError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ReadOnlyRoleError";
  }
}

export function readOnlyWorkerRequirement(
  role: ReadOnlyRole,
): WorkerRequirement {
  return {
    capability: roleCapabilities[role],
    role,
    permission: "repository_read",
  };
}

export function resolveReadOnlyWorker(
  registry: WorkerRegistry,
  role: ReadOnlyRole,
): ReturnType<WorkerRegistry["resolve"]> {
  return registry.resolve(readOnlyWorkerRequirement(role));
}

export interface ReadOnlyRoleExecution {
  readonly role: ReadOnlyRole;
  readonly workerId: string;
  readonly result: WorkerExecutionResult;
}

export interface ReadOnlyPanelInput {
  readonly request: WorkerExecutionRequest;
  readonly workers: Readonly<Partial<Record<ReadOnlyRole, WorkerExecutor>>>;
  readonly roles: readonly ReadOnlyRole[];
}

function validateWorker(role: ReadOnlyRole, worker: WorkerExecutor): void {
  if (!worker.resource.roles.includes(role)) {
    throw new ReadOnlyRoleError(
      `Worker ${worker.resource.id} is not registered for ${role}`,
    );
  }
  if (!worker.resource.capabilities.includes(roleCapabilities[role])) {
    throw new ReadOnlyRoleError(
      `Worker ${worker.resource.id} lacks ${roleCapabilities[role]}`,
    );
  }
  const forbidden = worker.resource.permissions.filter((permission) =>
    forbiddenPermissions.has(permission),
  );
  if (forbidden.length > 0) {
    throw new ReadOnlyRoleError(
      `Worker ${worker.resource.id} has write-capable permissions: ${forbidden.join(", ")}`,
    );
  }
}

export async function executeReadOnlyPanel(
  input: ReadOnlyPanelInput,
): Promise<readonly ReadOnlyRoleExecution[]> {
  if (input.roles.length === 0)
    throw new ReadOnlyRoleError("At least one read-only role is required");
  const seenIndependence = new Set<string>();
  const selected = input.roles.map((role) => {
    const worker = input.workers[role];
    if (!worker) throw new ReadOnlyRoleError(`No worker supplied for ${role}`);
    validateWorker(role, worker);
    if (seenIndependence.has(worker.resource.independenceKey)) {
      throw new ReadOnlyRoleError(
        `Read-only workers must be independent; ${worker.resource.id} shares an independence key`,
      );
    }
    seenIndependence.add(worker.resource.independenceKey);
    return { role, worker };
  });

  return Promise.all(
    selected.map(async ({ role, worker }) => ({
      role,
      workerId: worker.resource.id,
      result: await worker.execute({
        ...input.request,
        requestId: `${input.request.requestId}:readonly:${role}`,
        workerId: worker.resource.id,
        connectionId: worker.connection.id,
      }),
    })),
  );
}
