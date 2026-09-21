export interface WorkerPluginRepositoryTarget {
  readonly repositoryId: string;
  readonly revision: string;
  readonly workspaceSubpath?: string;
}

export interface WorkerPluginInput {
  readonly objective: string;
  readonly role: string;
  readonly input: Record<string, unknown>;
  readonly contextArtifactIds: readonly string[];
  readonly timeoutMs: number;
  readonly repository?: WorkerPluginRepositoryTarget;
  readonly config: Record<string, unknown>;
  readonly secrets: Record<string, string>;
}

export interface WorkerPluginContext {
  readonly workDir: string;
  readonly signal: AbortSignal;
  readonly config: Record<string, unknown>;
  readonly secrets: Record<string, string>;
  readonly log: (
    level: "debug" | "info" | "warn" | "error",
    message: string,
    context?: Record<string, unknown>,
  ) => void;
  readonly progress: (
    stage: string,
    percent?: number,
    logChunk?: string,
  ) => void;
  readonly emitArtifact: (id: string, path: string) => void;
  readonly emitFinding: (finding: unknown) => void;
}

export interface WorkerPluginOutput {
  readonly status: "completed" | "failed";
  readonly summary: string;
  readonly output: Record<string, unknown> | null;
  readonly artifactIds: readonly string[];
  readonly findings?: readonly unknown[];
  readonly evidence?: {
    readonly observedAt: string;
    readonly metrics?: Record<string, unknown>;
    readonly logs?: readonly string[];
  };
  readonly error?: {
    readonly code: string;
    readonly message: string;
    readonly retryable?: boolean;
  };
}

export type WorkerPluginHandler = (
  input: WorkerPluginInput,
  context: WorkerPluginContext,
) => Promise<WorkerPluginOutput>;
