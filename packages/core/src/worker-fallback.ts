import type {
  WorkerAssignmentRequest,
  WorkerAssignmentResponse,
  WorkerAssignmentRunner,
} from "./assignment-execution.js";

export interface WorkerFallbackAttempt {
  readonly workerId: string;
  readonly result: WorkerAssignmentResponse;
}

export interface WorkerFallbackResult {
  readonly selectedWorkerId: string | null;
  readonly result: WorkerAssignmentResponse;
  readonly attempts: readonly WorkerFallbackAttempt[];
}

export class WorkerFallbackError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "WorkerFallbackError";
  }
}

function canFallback(result: WorkerAssignmentResponse): boolean {
  return result.status === "failed" && result.error?.retryable === true;
}

/** Runs an ordered Worker assignment policy, falling back only on retryable failures. */
export async function executeWithFallback(
  request: WorkerAssignmentRequest,
  workers: readonly WorkerAssignmentRunner[],
): Promise<WorkerFallbackResult> {
  if (workers.length === 0)
    throw new WorkerFallbackError("At least one fallback worker is required");
  const attempts: WorkerFallbackAttempt[] = [];
  for (const worker of workers) {
    const result = await worker.execute({
      ...request,
      workerId: worker.worker.id,
      requestId: `${request.requestId}:fallback:${worker.worker.id}`,
    });
    attempts.push({
      workerId: worker.worker.id,
      result,
    });
    if (result.status === "completed") {
      return {
        selectedWorkerId: worker.worker.id,
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
    result: last.result,
    attempts,
  };
}
