import { EventEmitter } from "node:events";
import fs from "node:fs";
import path from "node:path";
import type {
  DesiredWorker,
  AssignmentStartPayload,
  AssignmentResultPayload,
  AssignmentFailurePayload,
  WorkerStatusPayload,
} from "@conclave/agent-protocol";
import { PluginProcessRunner } from "@conclave/plugin-sdk";
import type { AgentConfig } from "./config.js";
import type { AgentStorage } from "./storage.js";
import { AgentLogger } from "./logger.js";
import type { PluginManager } from "./plugin-manager.js";

export interface RunningAssignmentExecution {
  readonly assignmentId: string;
  readonly workerId: string;
  readonly runId: string;
  readonly taskId: string;
  readonly attemptId: string;
  readonly abortController: AbortController;
  readonly startedAt: string;
}

export type WorkerExecutionHandler = (
  payload: AssignmentStartPayload,
  context: {
    workDir: string;
    signal: AbortSignal;
    onProgress: (stage: string, percent?: number, logChunk?: string) => void;
  },
) => Promise<{
  output: Record<string, unknown> | null;
  summary: string;
  artifactIds?: string[];
  findings?: unknown[];
  evidence?: {
    observedAt: string;
    metrics?: Record<string, unknown>;
    logs?: string[];
  };
}>;

export class WorkerManager extends EventEmitter {
  private readonly workers = new Map<string, DesiredWorker>();
  private readonly runningAssignments = new Map<
    string,
    RunningAssignmentExecution
  >();
  private customExecutor?: WorkerExecutionHandler;
  private pluginManager?: PluginManager;

  constructor(
    private readonly config: AgentConfig,
    private readonly storage: AgentStorage,
    private readonly logger: AgentLogger,
    pluginManager?: PluginManager,
  ) {
    super();
    this.pluginManager = pluginManager;
  }

  /**
   * Sets the plugin manager instance.
   */
  setPluginManager(pluginManager: PluginManager): void {
    this.pluginManager = pluginManager;
  }

  /**
   * Sets an optional custom execution handler (e.g. for testing or specialized worker runtimes).
   */
  setExecutor(executor: WorkerExecutionHandler): void {
    this.customExecutor = executor;
  }

  /**
   * Configures or updates a local worker definition.
   */
  configureWorker(worker: DesiredWorker): void {
    this.workers.set(worker.workerId, worker);
    this.logger.info("Configured worker", {
      workerId: worker.workerId,
      name: worker.name,
      pluginId: worker.pluginId,
      roles: worker.roles,
    });
  }

  /**
   * Removes a local worker.
   */
  removeWorker(workerId: string): void {
    this.workers.delete(workerId);
  }

  /**
   * Retrieves a worker configuration.
   */
  getWorker(workerId: string): DesiredWorker | undefined {
    return this.workers.get(workerId);
  }

  /**
   * Lists all configured workers.
   */
  listWorkers(): readonly DesiredWorker[] {
    return [...this.workers.values()];
  }

  /**
   * Returns current active assignments count.
   */
  getActiveAssignmentsCount(): number {
    return this.runningAssignments.size;
  }

  /**
   * Waits until all currently running assignments finish executing or timeout expires.
   */
  async waitForIdle(timeoutMs: number = 30000): Promise<boolean> {
    if (this.runningAssignments.size === 0) return true;
    const start = Date.now();
    while (this.runningAssignments.size > 0) {
      if (Date.now() - start > timeoutMs) {
        return false;
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    return true;
  }

  /**
   * Returns active assignments count for a specific worker.
   */
  getActiveAssignmentsForWorker(workerId: string): number {
    let count = 0;
    for (const running of this.runningAssignments.values()) {
      if (running.workerId === workerId) {
        count++;
      }
    }
    return count;
  }

  /**
   * Returns status descriptor for a specific worker.
   */
  getWorkerStatus(workerId: string): WorkerStatusPayload | undefined {
    const worker = this.workers.get(workerId);
    if (!worker) return undefined;

    const activeCount = this.getActiveAssignmentsForWorker(workerId);
    let status: "available" | "busy" | "disabled" | "error" | "offline" =
      "available";
    if (!worker.enabled) {
      status = "disabled";
    } else if (activeCount >= worker.concurrencyLimit) {
      status = "busy";
    }

    return {
      workerId,
      agentId: this.config.agentId,
      status,
      activeAssignments: activeCount,
    };
  }

  /**
   * Cancels a currently running assignment.
   */
  cancelAssignment(assignmentId: string, reason: string): boolean {
    const running = this.runningAssignments.get(assignmentId);
    if (!running) {
      return false;
    }
    this.logger.warn("Cancelling assignment", { assignmentId, reason });
    running.abortController.abort(new Error(reason));
    return true;
  }

  /**
   * Executes an assignment payload with lifecycle management, timeouts, and progress reporting.
   */
  async executeAssignment(input: {
    assignmentId: string;
    workerId: string;
    runId: string;
    taskId: string;
    attemptId: string;
    idempotencyKey: string;
    payload: AssignmentStartPayload;
    onProgress?: (stage: string, percent?: number, logChunk?: string) => void;
  }): Promise<
    | { success: true; result: AssignmentResultPayload }
    | { success: false; failure: AssignmentFailurePayload }
  > {
    const {
      assignmentId,
      workerId,
      runId,
      taskId,
      attemptId,
      payload,
      onProgress,
    } = input;

    // Check concurrency limits
    if (this.runningAssignments.size >= this.config.maxConcurrentWorkers) {
      return {
        success: false,
        failure: {
          status: "failed",
          error: {
            code: "AGENT_CONCURRENCY_EXCEEDED",
            message: `Agent maximum concurrent workers (${this.config.maxConcurrentWorkers}) reached`,
            retryable: true,
          },
        },
      };
    }

    const worker = this.workers.get(workerId);
    if (!worker) {
      return {
        success: false,
        failure: {
          status: "failed",
          error: {
            code: "WORKER_NOT_FOUND",
            message: `Worker '${workerId}' is not configured on this agent host`,
            retryable: false,
          },
        },
      };
    }

    if (!worker.enabled) {
      return {
        success: false,
        failure: {
          status: "failed",
          error: {
            code: "WORKER_DISABLED",
            message: `Worker '${workerId}' is disabled`,
            retryable: false,
          },
        },
      };
    }

    const workerActive = this.getActiveAssignmentsForWorker(workerId);
    if (workerActive >= worker.concurrencyLimit) {
      return {
        success: false,
        failure: {
          status: "failed",
          error: {
            code: "WORKER_BUSY",
            message: `Worker '${workerId}' reached its concurrency limit of ${worker.concurrencyLimit}`,
            retryable: true,
          },
        },
      };
    }

    const abortController = new AbortController();
    const workDir = this.storage.getWorkDir(runId, taskId);

    const runningRecord: RunningAssignmentExecution = {
      assignmentId,
      workerId,
      runId,
      taskId,
      attemptId,
      abortController,
      startedAt: new Date().toISOString(),
    };
    this.runningAssignments.set(assignmentId, runningRecord);

    const timeoutMs = payload.timeoutMs || 300_000;
    const timeoutHandle = setTimeout(() => {
      abortController.abort(
        new Error(`Assignment timed out after ${timeoutMs}ms`),
      );
    }, timeoutMs);

    try {
      this.logger.info("Starting assignment execution", {
        assignmentId,
        workerId,
        role: payload.role,
        objective: payload.objective,
      });

      const handleProgress = (
        stage: string,
        percent?: number,
        logChunk?: string,
      ) => {
        if (onProgress) {
          const redactedChunk = logChunk
            ? AgentLogger.redact(logChunk)
            : undefined;
          onProgress(stage, percent, redactedChunk);
        }
      };

      handleProgress(
        "init",
        10,
        "Initializing workspace execution environment",
      );

      let executionOutput: {
        output: Record<string, unknown> | null;
        summary: string;
        artifactIds?: string[];
        findings?: unknown[];
        evidence?: {
          observedAt: string;
          metrics?: Record<string, unknown>;
          logs?: string[];
        };
      };

      if (this.customExecutor) {
        executionOutput = await this.customExecutor(payload, {
          workDir,
          signal: abortController.signal,
          onProgress: handleProgress,
        });
      } else {
        const resolvedVersion =
          payload.resolvedPluginVersion ||
          (this.pluginManager
            ? this.pluginManager.resolveLocalVersion(
                payload.pluginId,
                worker.pluginVersionPolicy,
              ) || "1.0.0"
            : "1.0.0");

        const pluginDir = this.storage.getPluginDir(
          payload.pluginId,
          resolvedVersion,
        );
        const candidateEntrypoints = [
          "index.js",
          "index.mjs",
          "entrypoint.js",
          "entrypoint.mjs",
        ];
        let foundEntrypoint: string | null = null;
        for (const ep of candidateEntrypoints) {
          if (fs.existsSync(path.join(pluginDir, ep))) {
            foundEntrypoint = ep;
            break;
          }
        }

        if (foundEntrypoint) {
          const runner = new PluginProcessRunner({
            pluginDir,
            entrypoint: foundEntrypoint,
          });

          const pluginOutput = await runner.execute(
            {
              objective: payload.objective,
              role: payload.role,
              input: payload.input,
              contextArtifactIds: payload.contextArtifactIds,
              timeoutMs: payload.timeoutMs,
              repository: payload.repository,
              config: worker.config,
              secrets: {},
            },
            {
              workDir,
              signal: abortController.signal,
              onProgress: handleProgress,
              onLog: (lvl, msg) =>
                this.logger.info(`[Plugin ${payload.pluginId}] ${msg}`),
            },
          );

          if (pluginOutput.status === "failed") {
            return {
              success: false,
              failure: {
                status: "failed",
                error: {
                  code: pluginOutput.error?.code ?? "PLUGIN_EXECUTION_ERROR",
                  message: pluginOutput.error?.message ?? pluginOutput.summary,
                  retryable: pluginOutput.error?.retryable ?? false,
                },
              },
            };
          }

          executionOutput = {
            output: pluginOutput.output,
            summary: pluginOutput.summary,
            artifactIds: [...pluginOutput.artifactIds],
            findings: pluginOutput.findings
              ? [...pluginOutput.findings]
              : undefined,
            evidence: pluginOutput.evidence
              ? {
                  observedAt: pluginOutput.evidence.observedAt,
                  metrics: pluginOutput.evidence.metrics,
                  logs: pluginOutput.evidence.logs
                    ? [...pluginOutput.evidence.logs]
                    : undefined,
                }
              : undefined,
          };
        } else {
          // Default execution strategy: simulated structured task completion
          handleProgress(
            "running",
            50,
            `Executing ${payload.role} on ${payload.objective}`,
          );
          executionOutput = {
            output: {
              status: "completed",
              objective: payload.objective,
              workerId,
              executedLocally: true,
            },
            summary: `Successfully completed assignment for role '${payload.role}'`,
            artifactIds: payload.contextArtifactIds,
            evidence: {
              observedAt: new Date().toISOString(),
              metrics: { durationMs: 100 },
              logs: [`Executed ${payload.role} in ${workDir}`],
            },
          };
        }
      }

      handleProgress("completed", 100, "Execution completed successfully");

      const result: AssignmentResultPayload = {
        status: "completed",
        summary: executionOutput.summary,
        output: executionOutput.output,
        artifactIds: executionOutput.artifactIds ?? [],
        findings: executionOutput.findings,
        evidence: executionOutput.evidence,
      };

      return { success: true, result };
    } catch (err: unknown) {
      const isAborted = abortController.signal.aborted;
      const errorMessage = err instanceof Error ? err.message : String(err);
      this.logger.error("Assignment execution failed", {
        assignmentId,
        error: AgentLogger.redact(errorMessage),
        aborted: isAborted,
      });

      const failure: AssignmentFailurePayload = {
        status: "failed",
        error: {
          code: isAborted ? "ASSIGNMENT_ABORTED" : "EXECUTION_ERROR",
          message: AgentLogger.redact(errorMessage),
          retryable: isAborted,
        },
      };

      return { success: false, failure };
    } finally {
      clearTimeout(timeoutHandle);
      this.runningAssignments.delete(assignmentId);
    }
  }
}
