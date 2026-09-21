import type {
  WorkerExecutionRequest,
  WorkerExecutionResult,
  WorkerExecutor,
} from "./worker-execution.js";

export interface WorkerFallbackAttempt {
  readonly workerId: string;
  readonly connectionId: string;
  readonly result: WorkerExecutionResult;
}

export interface WorkerFallbackResult {
  readonly selectedWorkerId: string | null;
  readonly selectedConnectionId: string | null;
  readonly result: WorkerExecutionResult;
  readonly attempts: readonly WorkerFallbackAttempt[];
}

export class WorkerFallbackError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "WorkerFallbackError";
  }
}

function canFallback(result: WorkerExecutionResult): boolean {
  return result.status === "failed" && result.error?.retryable === true;
}

/** Runs an ordered Worker/Connection policy, falling back only on retryable failures. */
export async function executeWithFallback(
  request: WorkerExecutionRequest,
  workers: readonly WorkerExecutor[],
): Promise<WorkerFallbackResult> {
  if (workers.length === 0)
    throw new WorkerFallbackError("At least one fallback worker is required");
  const attempts: WorkerFallbackAttempt[] = [];
  for (const worker of workers) {
    const result = await worker.execute({
      ...request,
      workerId: worker.resource.id,
      connectionId: worker.connection.id,
      requestId: `${request.requestId}:fallback:${worker.resource.id}`,
    });
    attempts.push({
      workerId: worker.resource.id,
      connectionId: worker.connection.id,
      result,
    });
    if (result.status === "succeeded") {
      return {
        selectedWorkerId: worker.resource.id,
        selectedConnectionId: worker.connection.id,
        result,
        attempts,
      };
    }
    if (!canFallback(result)) break;
  }
  const last = attempts.at(-1);
  if (!last)
    throw new WorkerFallbackError("Fallback policy produced no attempts");
  return {
    selectedWorkerId: null,
    selectedConnectionId: null,
    result: last.result,
    attempts,
  };
}
