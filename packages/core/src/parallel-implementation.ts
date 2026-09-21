import type {
  WorkerExecutionRequest,
  WorkerExecutionResult,
  WorkerExecutor,
} from "./worker-execution.js";

export interface ParallelImplementationInput {
  readonly request: WorkerExecutionRequest;
  readonly executions: readonly {
    readonly worker: WorkerExecutor;
    /** A Local Runtime repository ID backed by a dedicated Git worktree. */
    readonly workspaceRepositoryId: string;
  }[];
}

export interface ParallelImplementationResult {
  readonly workerId: string;
  readonly workspaceRepositoryId: string;
  readonly result: WorkerExecutionResult;
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
    if (workers.has(execution.worker.resource.id))
      throw new ParallelImplementationError("Worker cannot implement twice");
    if (workspaces.has(execution.workspaceRepositoryId))
      throw new ParallelImplementationError(
        "Each implementation worker requires a distinct workspace",
      );
    if (independenceKeys.has(execution.worker.resource.independenceKey))
      throw new ParallelImplementationError(
        "Parallel implementations require independent workers",
      );
    if (!execution.workspaceRepositoryId) {
      throw new ParallelImplementationError(
        "A workspace repository ID is required",
      );
    }
    workers.add(execution.worker.resource.id);
    workspaces.add(execution.workspaceRepositoryId);
    independenceKeys.add(execution.worker.resource.independenceKey);
  }
  return Promise.all(
    input.executions.map(async ({ worker, workspaceRepositoryId }) => ({
      workerId: worker.resource.id,
      workspaceRepositoryId,
      result: await worker.execute({
        ...input.request,
        requestId: `${input.request.requestId}:implementation:${worker.resource.id}`,
        workerId: worker.resource.id,
        connectionId: worker.connection.id,
        repositoryId: workspaceRepositoryId,
      }),
    })),
  );
}
