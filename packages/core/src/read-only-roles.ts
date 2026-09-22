import type {
  WorkerAssignmentRequest,
  WorkerAssignmentResponse,
  WorkerAssignmentRunner,
} from "./assignment-execution.js";
import type { Worker } from "./entities.js";

export type ReadOnlyRole = "researcher" | "architect" | "planner" | "reviewer";

const roleCapabilities: Record<ReadOnlyRole, string> = {
  researcher: "repository_research",
  architect: "architecture",
  planner: "planning",
  reviewer: "code_review",
};

export class ReadOnlyRoleError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ReadOnlyRoleError";
  }
}

export function resolveReadOnlyWorker(
  workers: readonly Worker[],
  role: ReadOnlyRole,
): Worker | null {
  return (
    workers.find(
      (worker) =>
        worker.enabled &&
        worker.availability === "available" &&
        worker.roles.includes(role) &&
        worker.capabilities.includes(roleCapabilities[role]),
    ) ?? null
  );
}

export interface ReadOnlyRoleExecution {
  readonly role: ReadOnlyRole;
  readonly workerId: string;
  readonly result: WorkerAssignmentResponse;
}

export interface ReadOnlyPanelInput {
  readonly request: WorkerAssignmentRequest;
  readonly workers: Readonly<
    Partial<Record<ReadOnlyRole, WorkerAssignmentRunner>>
  >;
  readonly roles: readonly ReadOnlyRole[];
}

function validateWorker(
  role: ReadOnlyRole,
  worker: WorkerAssignmentRunner,
): void {
  if (!worker.worker.roles.includes(role)) {
    throw new ReadOnlyRoleError(
      `Worker ${worker.worker.id} is not registered for ${role}`,
    );
  }
  if (!worker.worker.capabilities.includes(roleCapabilities[role])) {
    throw new ReadOnlyRoleError(
      `Worker ${worker.worker.id} lacks ${roleCapabilities[role]}`,
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
    if (seenIndependence.has(worker.worker.independenceKey)) {
      throw new ReadOnlyRoleError(
        `Read-only workers must be independent; ${worker.worker.id} shares an independence key`,
      );
    }
    seenIndependence.add(worker.worker.independenceKey);
    return { role, worker };
  });

  return Promise.all(
    selected.map(async ({ role, worker }) => ({
      role,
      workerId: worker.worker.id,
      result: await worker.execute({
        ...input.request,
        requestId: `${input.request.requestId}:readonly:${role}`,
        workerId: worker.worker.id,
      }),
    })),
  );
}
