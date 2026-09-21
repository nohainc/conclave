import { spawn, type ChildProcess } from "node:child_process";
import readline from "node:readline";
import path from "node:path";
import fs from "node:fs";
import type { WorkerPluginInput, WorkerPluginOutput } from "./types.js";

export interface PluginRunnerOptions {
  readonly pluginDir: string;
  readonly entrypoint: string;
  readonly executable?: string;
}

export class PluginProcessRunner {
  constructor(private readonly options: PluginRunnerOptions) {}

  /**
   * Executes a worker plugin out-of-process in a secure, isolated child process.
   * A crash or unhandled error in the plugin will NOT crash the host Agent process.
   */
  async execute(
    input: WorkerPluginInput,
    context: {
      workDir: string;
      signal: AbortSignal;
      onProgress?: (stage: string, percent?: number, logChunk?: string) => void;
      onLog?: (level: string, message: string) => void;
    },
  ): Promise<WorkerPluginOutput> {
    const entrypointPath = path.isAbsolute(this.options.entrypoint)
      ? this.options.entrypoint
      : path.join(this.options.pluginDir, this.options.entrypoint);

    if (!fs.existsSync(entrypointPath)) {
      return {
        status: "failed",
        summary: `Plugin entrypoint not found at ${entrypointPath}`,
        output: null,
        artifactIds: [],
        error: {
          code: "PLUGIN_ENTRYPOINT_NOT_FOUND",
          message: `Plugin entrypoint does not exist: ${entrypointPath}`,
          retryable: false,
        },
      };
    }

    const command = this.options.executable ?? "node";
    const args = [entrypointPath];

    const childEnv: Record<string, string> = {
      ...(process.env as Record<string, string>),
      CONCLAVE_PLUGIN_CHILD_PROCESS: "true",
      CONCLAVE_WORK_DIR: context.workDir,
    };

    let resultOutput: WorkerPluginOutput | null = null;
    let stderrAccumulator = "";
    const emittedArtifacts = new Set<string>();
    const emittedFindings: unknown[] = [];

    return new Promise<WorkerPluginOutput>((resolve) => {
      let isSettled = false;

      const finish = (output: WorkerPluginOutput) => {
        if (isSettled) return;
        isSettled = true;
        clearTimeout(timeoutTimer);
        context.signal.removeEventListener("abort", handleAbort);
        resolve(output);
      };

      const child: ChildProcess = spawn(command, args, {
        cwd: context.workDir,
        env: childEnv as NodeJS.ProcessEnv,
        stdio: ["pipe", "pipe", "pipe"],
      });

      // Handle abort signal
      const handleAbort = () => {
        try {
          child.kill("SIGTERM");
          setTimeout(() => {
            if (!child.killed) {
              child.kill("SIGKILL");
            }
          }, 2000);
        } catch {
          // ignore kill errors
        }
      };
      context.signal.addEventListener("abort", handleAbort);

      // Handle execution timeout
      const timeoutMs = input.timeoutMs || 300_000;
      const timeoutTimer = setTimeout(() => {
        try {
          child.kill("SIGKILL");
        } catch {
          // ignore
        }
        finish({
          status: "failed",
          summary: `Plugin execution timed out after ${timeoutMs}ms`,
          output: null,
          artifactIds: [...emittedArtifacts],
          error: {
            code: "PLUGIN_TIMEOUT",
            message: `Plugin exceeded maximum allowed runtime of ${timeoutMs}ms`,
            retryable: true,
          },
        });
      }, timeoutMs);

      if (!child.stdout || !child.stdin || !child.stderr) {
        finish({
          status: "failed",
          summary: "Child process stdio streams not available",
          output: null,
          artifactIds: [],
          error: {
            code: "PLUGIN_SPAWN_ERROR",
            message: "Child process stdio streams were not piped",
            retryable: false,
          },
        });
        return;
      }

      // Read structured stdout line by line
      const rl = readline.createInterface({
        input: child.stdout,
        terminal: false,
      });

      rl.on("line", (line) => {
        if (!line.trim()) return;
        try {
          const parsed = JSON.parse(line) as {
            type: string;
            stage?: string;
            percent?: number;
            logChunk?: string;
            level?: string;
            message?: string;
            artifactId?: string;
            finding?: unknown;
            output?: WorkerPluginOutput;
          };

          if (
            parsed.type === "progress" &&
            context.onProgress &&
            parsed.stage
          ) {
            context.onProgress(parsed.stage, parsed.percent, parsed.logChunk);
          } else if (
            parsed.type === "log" &&
            context.onLog &&
            parsed.level &&
            parsed.message
          ) {
            context.onLog(parsed.level, parsed.message);
          } else if (parsed.type === "artifact" && parsed.artifactId) {
            emittedArtifacts.add(parsed.artifactId);
          } else if (
            parsed.type === "finding" &&
            parsed.finding !== undefined
          ) {
            emittedFindings.push(parsed.finding);
          } else if (parsed.type === "result" && parsed.output) {
            resultOutput = parsed.output;
          }
        } catch {
          // Non-JSON raw stdout log line
          if (context.onProgress) {
            context.onProgress("running", undefined, line);
          }
        }
      });

      // Capture stderr
      child.stderr.on("data", (chunk: Buffer) => {
        const text = chunk.toString();
        stderrAccumulator += text;
        if (context.onLog) {
          context.onLog("error", text);
        }
      });

      // Send input payload to child stdin
      try {
        const payloadJson = JSON.stringify({
          input,
          workDir: context.workDir,
        });
        child.stdin.write(`${payloadJson}\n`);
        child.stdin.end();
      } catch (err) {
        finish({
          status: "failed",
          summary: "Failed to pipe input to plugin process",
          output: null,
          artifactIds: [],
          error: {
            code: "PLUGIN_IPC_ERROR",
            message: err instanceof Error ? err.message : String(err),
            retryable: false,
          },
        });
        return;
      }

      // Handle spawn error
      child.on("error", (err) => {
        finish({
          status: "failed",
          summary: `Failed to spawn plugin process: ${err.message}`,
          output: null,
          artifactIds: [],
          error: {
            code: "PLUGIN_SPAWN_ERROR",
            message: err.message,
            retryable: false,
          },
        });
      });

      // Handle child process exit
      child.on("close", (exitCode, signal) => {
        if (isSettled) return;

        if (context.signal.aborted) {
          finish({
            status: "failed",
            summary: "Plugin execution was cancelled by agent",
            output: null,
            artifactIds: [...emittedArtifacts],
            error: {
              code: "PLUGIN_ABORTED",
              message: "Execution cancelled",
              retryable: true,
            },
          });
          return;
        }

        if (resultOutput) {
          const combinedArtifacts = Array.from(
            new Set([...(resultOutput.artifactIds ?? []), ...emittedArtifacts]),
          );
          finish({
            ...resultOutput,
            artifactIds: combinedArtifacts,
            findings:
              resultOutput.findings ??
              (emittedFindings.length > 0 ? emittedFindings : undefined),
          });
          return;
        }

        if (exitCode !== 0) {
          finish({
            status: "failed",
            summary: `Plugin process crashed with exit code ${exitCode ?? signal ?? -1}`,
            output: null,
            artifactIds: [...emittedArtifacts],
            error: {
              code: "PLUGIN_CRASHED",
              message:
                stderrAccumulator.trim() ||
                `Process exited with code ${exitCode} (${signal ?? "UNKNOWN_SIGNAL"})`,
              retryable: false,
            },
          });
          return;
        }

        // Exited 0 but no result was emitted
        finish({
          status: "completed",
          summary: "Plugin process exited successfully",
          output: {},
          artifactIds: [...emittedArtifacts],
          findings: emittedFindings.length > 0 ? emittedFindings : undefined,
        });
      });
    });
  }
}
