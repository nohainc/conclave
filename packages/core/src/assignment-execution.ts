import type { Worker, WorkerAssignmentResult } from "./entities.js";

export interface AssignmentContextItem {
  readonly artifactId: string;
  readonly mediaType: string;
  readonly content: string;
  readonly truncated: boolean;
  readonly originalLength: number;
  readonly estimatedTokens: number;
}

export interface WorkerAssignmentRequest {
  readonly requestId: string;
  readonly goalId: string;
  readonly runId: string;
  readonly taskId: string;
  readonly attemptId: string;
  readonly workerId: string;
  readonly repositoryId: string;
  readonly message: unknown;
  readonly context: readonly AssignmentContextItem[];
  readonly systemPrompt?: string;
  readonly signal?: AbortSignal;
  readonly deadlineAt?: string;
}

export type WorkerAssignmentResponseStatus =
  "completed" | "failed" | "cancelled";

export interface WorkerAssignmentResponse extends WorkerAssignmentResult {
  readonly status: WorkerAssignmentResponseStatus;
  readonly output: Record<string, unknown> | null;
  readonly usage?: {
    readonly inputTokens: number | null;
    readonly outputTokens: number | null;
  };
}

export interface WorkerAssignmentRunner {
  readonly worker: Worker;
  execute(request: WorkerAssignmentRequest): Promise<WorkerAssignmentResponse>;
}
