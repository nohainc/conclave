import type {
  WorkerAssignmentRequest,
  WorkerAssignmentResponse,
  WorkerAssignmentRunner,
} from "./assignment-execution.js";
import {
  DecisionResultSchema,
  PROTOCOL_NAME,
  PROTOCOL_VERSION,
  TaskRequestSchema,
  validateResponseContext,
  type DecisionResult,
  type TaskRequest,
} from "@conclave/protocol";

export type ExecutionPolicyMode =
  "single" | "parallel" | "synthesize" | "compare_and_select";

export interface ExecutionPolicy {
  readonly mode: ExecutionPolicyMode;
  /** Maximum number of candidate workers started at once. */
  readonly maxParallel?: number;
}

export interface ExecutionPolicyInput {
  readonly policy: ExecutionPolicy;
  readonly request: WorkerAssignmentRequest;
  readonly workers: readonly WorkerAssignmentRunner[];
  /** Required by `synthesize`; must not be one of the candidate workers. */
  readonly synthesizer?: WorkerAssignmentRunner;
  /** Required by `compare_and_select`; must not be one of the candidate workers. */
  readonly selector?: WorkerAssignmentRunner;
}

export interface ExecutionPolicyResult {
  readonly mode: ExecutionPolicyMode;
  readonly candidateResults: readonly WorkerAssignmentResponse[];
  /** The synthesis or comparison decision, when the policy has one. */
  readonly decisionResult: WorkerAssignmentResponse | null;
  /** Parsed Core decision emitted by the ordinary synthesis Task. */
  readonly decision: DecisionResult | null;
  /** The ordinary TaskRequest used to ask for synthesis/evaluation. */
  readonly decisionTask: TaskRequest | null;
}

export class ExecutionPolicyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ExecutionPolicyError";
  }
}

function ensureDistinct(
  workers: readonly WorkerAssignmentRunner[],
  special: WorkerAssignmentRunner | undefined,
  label: string,
): void {
  if (!special) throw new ExecutionPolicyError(`${label} worker is required`);
  if (workers.some((worker) => worker.worker.id === special.worker.id)) {
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
  workers: readonly WorkerAssignmentRunner[],
  request: WorkerAssignmentRequest,
  maxParallel: number | undefined,
): Promise<WorkerAssignmentResponse[]> {
  const results: WorkerAssignmentResponse[] = [];
  const limit = maxParallel ?? workers.length;
  for (let offset = 0; offset < workers.length; offset += limit) {
    const batch = workers.slice(offset, offset + limit);
    results.push(
      ...(await Promise.all(
        batch.map((worker) =>
          worker.execute({
            ...request,
            requestId: `${request.requestId}:${worker.worker.id}`,
            attemptId: `${request.attemptId}:candidate:${worker.worker.id}`,
            workerId: worker.worker.id,
          }),
        ),
      )),
    );
  }
  return results;
}

function decisionRequest(
  request: WorkerAssignmentRequest,
  mode: "synthesize" | "compare_and_select",
  candidateResults: readonly WorkerAssignmentResponse[],
  worker: WorkerAssignmentRunner,
): { request: WorkerAssignmentRequest; task: TaskRequest } {
  const taskId = `${request.taskId}:${mode}`;
  const task = TaskRequestSchema.parse({
    protocol: PROTOCOL_NAME,
    version: PROTOCOL_VERSION,
    messageId: `${request.requestId}:${mode}:task`,
    goalId: request.goalId,
    runId: request.runId,
    workerId: worker.worker.id,
    createdAt: new Date().toISOString(),
    messageType: "TaskRequest",
    payload: {
      taskId,
      objective:
        mode === "synthesize"
          ? "Synthesize the candidate outputs into one decision"
          : "Compare the candidate outputs and select the strongest result",
      role: mode === "synthesize" ? "synthesizer" : "evaluator",
      requiredCapabilities: [mode],
      contextArtifactIds: request.context.map((item) => item.artifactId),
      inputs: {
        sourceTaskId: request.taskId,
        candidates: candidateResults.map((result, index) => ({
          index,
          status: result.status,
          output: result.output,
          error: result.error ?? null,
        })),
      },
    },
  });
  return {
    request: {
      ...request,
      requestId: `${request.requestId}:${mode}`,
      attemptId: `${request.attemptId}:decision:${mode}`,
      taskId,
      workerId: worker.worker.id,
      message: task,
    },
    task,
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
    return {
      mode: input.policy.mode,
      candidateResults,
      decisionResult: null,
      decision: null,
      decisionTask: null,
    };
  }
  const decisionWorker =
    input.policy.mode === "synthesize" ? input.synthesizer : input.selector;
  const decisionRequestValue = decisionRequest(
    input.request,
    input.policy.mode,
    candidateResults,
    decisionWorker!,
  );
  const decisionResult = await decisionWorker!.execute(
    decisionRequestValue.request,
  );
  if (decisionResult.status !== "completed" || decisionResult.output === null) {
    return {
      mode: input.policy.mode,
      candidateResults,
      decisionResult,
      decision: null,
      decisionTask: decisionRequestValue.task,
    };
  }
  const decision = DecisionResultSchema.parse(decisionResult.output);
  validateResponseContext(decision, {
    goalId: input.request.goalId,
    runId: input.request.runId,
    workerId: decisionWorker!.worker.id,
    taskId: decisionRequestValue.task.payload.taskId,
    expectedMessageType: "DecisionResult",
  });
  return {
    mode: input.policy.mode,
    candidateResults,
    decisionResult,
    decision,
    decisionTask: decisionRequestValue.task,
  };
}
