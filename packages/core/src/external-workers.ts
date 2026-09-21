import {
  parseModelResult,
  validateResponseContext,
  type ModelResult,
} from "@conclave/protocol";

import type {
  ConnectionResource,
  WorkerExecutionRequest,
  WorkerExecutionResult,
  WorkerExecutor,
  WorkerResource,
} from "./index.js";

export interface RemoteWorkerChannel {
  execute(request: WorkerExecutionRequest): Promise<unknown>;
  cancel?(executionId: string): Promise<void>;
}

export class RemoteWorkerError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RemoteWorkerError";
  }
}

function isResult(value: unknown): value is WorkerExecutionResult {
  if (typeof value !== "object" || value === null) return false;
  const record = value as Record<string, unknown>;
  return (
    ["succeeded", "failed", "waiting", "cancelled"].includes(
      record.status as string,
    ) &&
    (record.output === null || typeof record.output === "string") &&
    (record.rawOutput === null || typeof record.rawOutput === "string") &&
    typeof record.usage === "object" &&
    record.usage !== null &&
    Array.isArray(record.evidenceArtifactIds)
  );
}

/** Executes a custom remote agent without teaching Core its protocol or vendor. */
export class RemoteWorkerExecutor implements WorkerExecutor {
  constructor(
    readonly resource: WorkerResource,
    readonly connection: ConnectionResource,
    private readonly channel: RemoteWorkerChannel,
  ) {}

  async execute(
    request: WorkerExecutionRequest,
  ): Promise<WorkerExecutionResult> {
    const response = await this.channel.execute(request);
    const envelope =
      typeof response === "object" && response !== null && "result" in response
        ? (response as { result: unknown }).result
        : response;
    if (!isResult(envelope)) {
      throw new RemoteWorkerError(
        "Remote worker returned an invalid WorkerExecutionResult",
      );
    }
    const executionId =
      typeof response === "object" &&
      response !== null &&
      "executionId" in response
        ? (response as { executionId?: unknown }).executionId
        : undefined;
    return executionId === undefined
      ? envelope
      : { ...envelope, executionId: String(executionId) };
  }

  async cancel(executionId: string): Promise<void> {
    await this.channel.cancel?.(executionId);
  }
}

export interface ManualSubmissionOptions {
  readonly expectedMessageType: ModelResult["messageType"];
}

export interface ManualSubmissionResult {
  readonly accepted: boolean;
  readonly executionId: string;
  readonly result: WorkerExecutionResult;
}

interface ManualPendingExecution {
  readonly request: WorkerExecutionRequest;
  readonly executionId: string;
}

/**
 * Bridges unsupported AI services or human operators into the normal worker
 * lifecycle. Execution is explicitly waiting until submit() validates output.
 */
export class ManualWorkerExecutor implements WorkerExecutor {
  private readonly pending = new Map<string, ManualPendingExecution>();

  constructor(
    readonly resource: WorkerResource,
    readonly connection: ConnectionResource,
    private readonly executionIdFactory: (
      request: WorkerExecutionRequest,
    ) => string = (request) => `manual:${request.requestId}`,
  ) {}

  execute(request: WorkerExecutionRequest): Promise<WorkerExecutionResult> {
    const executionId = this.executionIdFactory(request);
    this.pending.set(executionId, { request, executionId });
    return Promise.resolve({
      status: "waiting",
      output: null,
      rawOutput: null,
      executionId,
      usage: { inputTokens: null, outputTokens: null },
      evidenceArtifactIds: [],
    });
  }

  async submit(
    executionId: string,
    output: unknown,
    options: ManualSubmissionOptions,
  ): Promise<ManualSubmissionResult> {
    const pending = this.pending.get(executionId);
    if (!pending) {
      throw new RemoteWorkerError(
        `Manual execution ${executionId} is not pending`,
      );
    }
    try {
      const parsed = parseModelResult(
        typeof output === "string" ? JSON.parse(output) : output,
      );
      validateResponseContext(parsed, {
        goalId: pending.request.goalId,
        runId: pending.request.runId,
        workerId: pending.request.workerId,
        taskId: pending.request.taskId,
        expectedMessageType: options.expectedMessageType,
      });
      this.pending.delete(executionId);
      return {
        accepted: true,
        executionId,
        result: {
          status: "succeeded",
          output: JSON.stringify(parsed),
          rawOutput:
            typeof output === "string" ? output : JSON.stringify(output),
          executionId,
          usage: { inputTokens: null, outputTokens: null },
          evidenceArtifactIds: [],
        },
      };
    } catch (error) {
      return {
        accepted: false,
        executionId,
        result: {
          status: "failed",
          output: null,
          rawOutput:
            typeof output === "string" ? output : JSON.stringify(output),
          executionId,
          usage: { inputTokens: null, outputTokens: null },
          evidenceArtifactIds: [],
          error: {
            code: "manual_output_rejected",
            message:
              error instanceof Error ? error.message : "Invalid manual output",
            retryable: false,
          },
        },
      };
    }
  }

  cancel(executionId: string): boolean {
    return this.pending.delete(executionId);
  }

  pendingExecutionIds(): readonly string[] {
    return [...this.pending.keys()];
  }
}
