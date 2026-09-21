import type {
  WorkerExecutionRequest,
  WorkerExecutionResult,
  WorkerExecutor,
} from "./worker-execution.js";

export type ExecutionPolicyMode =
  "single" | "parallel" | "synthesize" | "compare_and_select";

export interface ExecutionPolicy {
  readonly mode: ExecutionPolicyMode;
  /** Maximum number of candidate workers started at once. */
  readonly maxParallel?: number;
}

export interface ExecutionPolicyInput {
  readonly policy: ExecutionPolicy;
  readonly request: WorkerExecutionRequest;
  readonly workers: readonly WorkerExecutor[];
  /** Required by `synthesize`; must not be one of the candidate workers. */
  readonly synthesizer?: WorkerExecutor;
  /** Required by `compare_and_select`; must not be one of the candidate workers. */
  readonly selector?: WorkerExecutor;
}

export interface ExecutionPolicyResult {
  readonly mode: ExecutionPolicyMode;
  readonly candidateResults: readonly WorkerExecutionResult[];
  /** The synthesis or comparison decision, when the policy has one. */
  readonly decisionResult: WorkerExecutionResult | null;
}

export class ExecutionPolicyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ExecutionPolicyError";
  }
}

function ensureDistinct(
  workers: readonly WorkerExecutor[],
  special: WorkerExecutor | undefined,
  label: string,
): void {
  if (!special) throw new ExecutionPolicyError(`${label} worker is required`);
  if (workers.some((worker) => worker.resource.id === special.resource.id)) {
    throw new ExecutionPolicyError(
      `${label} worker must be independent from candidate workers`,
    );
  }
}

function validate(input: ExecutionPolicyInput): void {
  const { policy, workers } = input;
  if (workers.length === 0)
    throw new ExecutionPolicyError("At least one worker is required");
  if (policy.mode === "single" && workers.length !== 1) {
    throw new ExecutionPolicyError("Single policy requires exactly one worker");
  }
  if (
    policy.maxParallel !== undefined &&
    (!Number.isInteger(policy.maxParallel) || policy.maxParallel < 1)
  ) {
    throw new ExecutionPolicyError("maxParallel must be a positive integer");
  }
  if (policy.mode === "synthesize") {
    if (workers.length < 2)
      throw new ExecutionPolicyError(
        "Synthesis requires at least two candidates",
      );
    ensureDistinct(workers, input.synthesizer, "Synthesizer");
  }
  if (policy.mode === "compare_and_select") {
    if (workers.length < 2)
      throw new ExecutionPolicyError(
        "Comparison requires at least two candidates",
      );
    ensureDistinct(workers, input.selector, "Selector");
  }
}

async function runCandidates(
  workers: readonly WorkerExecutor[],
  request: WorkerExecutionRequest,
  maxParallel: number | undefined,
): Promise<WorkerExecutionResult[]> {
  const results: WorkerExecutionResult[] = [];
  const limit = maxParallel ?? workers.length;
  for (let offset = 0; offset < workers.length; offset += limit) {
    const batch = workers.slice(offset, offset + limit);
    results.push(
      ...(await Promise.all(
        batch.map((worker) =>
          worker.execute({
            ...request,
            requestId: `${request.requestId}:${worker.resource.id}`,
            workerId: worker.resource.id,
            connectionId: worker.connection.id,
          }),
        ),
      )),
    );
  }
  return results;
}

function decisionRequest(
  request: WorkerExecutionRequest,
  mode: "synthesize" | "compare_and_select",
  candidateResults: readonly WorkerExecutionResult[],
  worker: WorkerExecutor,
): WorkerExecutionRequest {
  return {
    ...request,
    requestId: `${request.requestId}:${mode}`,
    workerId: worker.resource.id,
    connectionId: worker.connection.id,
    message: {
      type: mode,
      originalMessage: request.message,
      candidates: candidateResults.map((result, index) => ({
        index,
        status: result.status,
        output: result.output,
        error: result.error ?? null,
      })),
    },
  };
}

export async function executeWithPolicy(
  input: ExecutionPolicyInput,
): Promise<ExecutionPolicyResult> {
  validate(input);
  const candidateResults = await runCandidates(
    input.workers,
    input.request,
    input.policy.maxParallel,
  );
  if (input.policy.mode === "single" || input.policy.mode === "parallel") {
    return { mode: input.policy.mode, candidateResults, decisionResult: null };
  }
  const decisionWorker =
    input.policy.mode === "synthesize" ? input.synthesizer : input.selector;
  const decisionResult = await decisionWorker!.execute(
    decisionRequest(
      input.request,
      input.policy.mode,
      candidateResults,
      decisionWorker!,
    ),
  );
  return { mode: input.policy.mode, candidateResults, decisionResult };
}
