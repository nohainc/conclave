import type {
  WorkerAssignmentRequest,
  WorkerAssignmentResponse,
  WorkerAssignmentRunner,
} from "./assignment-execution.js";

export interface ParallelImplementationInput {
  readonly request: WorkerAssignmentRequest;
  readonly executions: readonly {
    readonly worker: WorkerAssignmentRunner;
    /** A Local Runtime repository ID backed by a dedicated Git worktree. */
    readonly workspaceRepositoryId: string;
  }[];
}

export interface ParallelImplementationResult {
  readonly workerId: string;
  readonly workspaceRepositoryId: string;
  readonly result: WorkerAssignmentResponse;
}

export class ParallelImplementationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ParallelImplementationError";
  }
}

export async function executeParallelImplementations(
  input: ParallelImplementationInput,
): Promise<readonly ParallelImplementationResult[]> {
  if (input.executions.length < 2) {
    throw new ParallelImplementationError(
      "Parallel implementation requires at least two workers",
    );
  }
  const workers = new Set<string>();
  const workspaces = new Set<string>();
  const independenceKeys = new Set<string>();
  for (const execution of input.executions) {
    if (workers.has(execution.worker.worker.id))
      throw new ParallelImplementationError("Worker cannot implement twice");
    if (workspaces.has(execution.workspaceRepositoryId))
      throw new ParallelImplementationError(
        "Each implementation worker requires a distinct workspace",
      );
    if (independenceKeys.has(execution.worker.worker.independenceKey))
      throw new ParallelImplementationError(
        "Parallel implementations require independent workers",
      );
    if (!execution.workspaceRepositoryId) {
      throw new ParallelImplementationError(
        "A workspace repository ID is required",
      );
    }
    workers.add(execution.worker.worker.id);
    workspaces.add(execution.workspaceRepositoryId);
    independenceKeys.add(execution.worker.worker.independenceKey);
  }
  return Promise.all(
    input.executions.map(async ({ worker, workspaceRepositoryId }) => ({
      workerId: worker.worker.id,
      workspaceRepositoryId,
      result: await worker.execute({
        ...input.request,
        requestId: `${input.request.requestId}:implementation:${worker.worker.id}`,
        workerId: worker.worker.id,
        repositoryId: workspaceRepositoryId,
      }),
    })),
  );
}
