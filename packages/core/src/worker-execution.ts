export interface WorkerExecutionContextItem {
  readonly artifactId: string;
  readonly mediaType: string;
  readonly content: string;
  readonly truncated: boolean;
  readonly originalLength: number;
  readonly estimatedTokens: number;
}

export interface WorkerExecutionRequest {
  readonly requestId: string;
  readonly goalId: string;
  readonly runId: string;
  readonly taskId: string;
  readonly attemptId: string;
  readonly workerId: string;
  readonly connectionId: string;
  readonly repositoryId: string;
  readonly message: unknown;
  readonly context: readonly WorkerExecutionContextItem[];
  readonly systemPrompt?: string;
  readonly signal?: AbortSignal;
  readonly deadlineAt?: string;
}

export type WorkerExecutionStatus =
  "succeeded" | "failed" | "waiting" | "cancelled";

export interface WorkerExecutionResult {
  readonly status: WorkerExecutionStatus;
  readonly output: string | null;
  readonly rawOutput: string | null;
  readonly executionId?: string;
  readonly providerRequestId?: string;
  readonly usage: {
    readonly inputTokens: number | null;
    readonly outputTokens: number | null;
  };
  readonly evidenceArtifactIds: readonly string[];
  readonly error?: {
    readonly code: string;
    readonly message: string;
    readonly retryable: boolean;
  };
}

export interface WorkerExecutor {
  readonly resource: import("./worker-registry.js").WorkerResource;
  readonly connection: import("./worker-registry.js").ExecutionChannel;
  execute(request: WorkerExecutionRequest): Promise<WorkerExecutionResult>;
}
