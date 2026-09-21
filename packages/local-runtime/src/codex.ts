import { realpathSync } from "node:fs";
import { spawn as nodeSpawn, type ChildProcess } from "node:child_process";
import { resolve } from "node:path";

import type {
  WorkerExecutionRequest,
  WorkerExecutionResult,
} from "@conclave/core";

import type {
  LocalWorkerExecutor,
  RuntimeRepository,
  RuntimeWorkerDescriptor,
} from "./index.js";

export interface CodexLocalAgentOptions {
  readonly descriptor: RuntimeWorkerDescriptor;
  readonly repositories: readonly RuntimeRepository[];
  readonly executable?: string;
  /** Additional arguments placed before the prompt. Defaults to `exec --json --full-auto`. */
  readonly args?: readonly string[];
  readonly timeoutMs?: number;
  readonly maxStdoutBytes?: number;
  readonly maxStderrBytes?: number;
  readonly spawn?: CodexSpawn;
}

interface CodexSpawnOptions {
  readonly cwd: string;
  readonly shell: false;
  readonly detached: boolean;
  readonly windowsHide: boolean;
  readonly stdio: ["ignore", "pipe", "pipe"];
}

export interface CodexChild {
  readonly pid?: number;
  readonly stdout: {
    on(event: "data", listener: (chunk: Buffer) => void): void;
  };
  readonly stderr: {
    on(event: "data", listener: (chunk: Buffer) => void): void;
  };
  on(event: "error", listener: (error: Error) => void): void;
  on(event: "close", listener: (code: number | null) => void): void;
  kill(signal?: NodeJS.Signals): void;
}

export type CodexSpawn = (
  executable: string,
  args: readonly string[],
  options: CodexSpawnOptions,
) => CodexChild;

interface ProtocolEnvelope {
  readonly messageType: string;
  readonly payload: Record<string, unknown>;
}

function defaultSpawn(
  executable: string,
  args: readonly string[],
  options: CodexSpawnOptions,
): ChildProcess {
  return nodeSpawn(executable, [...args], options) as unknown as ChildProcess;
}

function boundedAppend(
  current: string,
  chunk: Buffer,
  limit: number,
): { value: string; truncated: boolean } {
  const next = `${current}${chunk.toString("utf8")}`;
  if (Buffer.byteLength(next) <= limit)
    return { value: next, truncated: false };
  return { value: next.slice(0, limit), truncated: true };
}

function parseEnvelope(output: string): ProtocolEnvelope | null {
  const candidates = output
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .flatMap((line) => {
      const withoutFence = line.replace(/^```(?:json)?\s*|```$/g, "");
      try {
        return [JSON.parse(withoutFence) as unknown];
      } catch {
        return [];
      }
    });

  for (const candidate of candidates) {
    if (typeof candidate !== "object" || candidate === null) continue;
    const value = candidate as Record<string, unknown>;
    if (
      typeof value.messageType === "string" &&
      typeof value.payload === "object" &&
      value.payload !== null &&
      !Array.isArray(value.payload)
    ) {
      return {
        messageType: value.messageType,
        payload: value.payload as Record<string, unknown>,
      };
    }
  }
  return null;
}

function promptFor(request: WorkerExecutionRequest): string {
  return [
    "You are a Conclave local implementation agent.",
    "Work only inside the repository working directory provided by the runtime.",
    "Return exactly one JSON object with this shape and no prose:",
    '{"messageType":"ImplementationResult","payload":{...}}',
    "The payload must be a valid Conclave protocol result. Describe proposed file operations explicitly; the runtime records and applies only approved operations.",
    "Conclave task request:",
    JSON.stringify(request.message),
    "Context artifacts:",
    JSON.stringify(request.context),
    request.systemPrompt
      ? `Additional system instructions:\n${request.systemPrompt}`
      : "",
  ]
    .filter(Boolean)
    .join("\n\n");
}

export class CodexLocalAgent implements LocalWorkerExecutor {
  readonly descriptor: RuntimeWorkerDescriptor;
  private readonly roots: ReadonlyMap<string, string>;
  private readonly executable: string;
  private readonly args: readonly string[];
  private readonly timeoutMs: number;
  private readonly maxStdoutBytes: number;
  private readonly maxStderrBytes: number;
  private readonly spawn: CodexSpawn;

  constructor(options: CodexLocalAgentOptions) {
    this.descriptor = options.descriptor;
    this.executable = options.executable ?? "codex";
    this.args = options.args ?? ["exec", "--json", "--full-auto"];
    this.timeoutMs = options.timeoutMs ?? 15 * 60_000;
    this.maxStdoutBytes = options.maxStdoutBytes ?? 2_000_000;
    this.maxStderrBytes = options.maxStderrBytes ?? 512_000;
    this.spawn = options.spawn ?? (defaultSpawn as CodexSpawn);
    this.roots = new Map(
      options.repositories.map((repository) => [
        repository.id,
        realpathSync(resolve(repository.root)),
      ]),
    );
  }

  execute(request: WorkerExecutionRequest): Promise<WorkerExecutionResult> {
    const cwd = this.roots.get(request.repositoryId);
    if (!cwd) {
      return Promise.resolve(
        this.failure(
          "repository_not_registered",
          `Repository ${request.repositoryId} is not registered`,
          false,
        ),
      );
    }
    if (
      request.workerId !== this.descriptor.workerId ||
      request.connectionId !== this.descriptor.connectionId
    ) {
      return Promise.resolve(
        this.failure(
          "worker_context_mismatch",
          "Request is not addressed to this Codex worker",
          false,
        ),
      );
    }

    return new Promise((resolveResult) => {
      let stdout = "";
      let stderr = "";
      let stdoutTruncated = false;
      let stderrTruncated = false;
      let timedOut = false;
      let cancelled = false;
      let settled = false;
      const finish = (result: WorkerExecutionResult) => {
        if (settled) return;
        settled = true;
        resolveResult(result);
      };
      const terminate = () => {
        const child = processHandle;
        if (!child) return;
        if (process.platform !== "win32" && child.pid) {
          try {
            process.kill(-child.pid, "SIGTERM");
            return;
          } catch {
            // Fall through to the child handle when the process group is gone.
          }
        }
        child.kill("SIGTERM");
      };
      let processHandle: CodexChild | undefined;
      const timer = setTimeout(() => {
        timedOut = true;
        terminate();
      }, this.timeoutMs);
      const onAbort = () => {
        cancelled = true;
        terminate();
      };
      request.signal?.addEventListener("abort", onAbort, { once: true });
      try {
        processHandle = this.spawn(
          this.executable,
          [...this.args, promptFor(request)],
          {
            cwd,
            shell: false,
            detached: process.platform !== "win32",
            windowsHide: true,
            stdio: ["ignore", "pipe", "pipe"],
          },
        );
        processHandle.stdout.on("data", (chunk) => {
          const next = boundedAppend(stdout, chunk, this.maxStdoutBytes);
          stdout = next.value;
          stdoutTruncated ||= next.truncated;
          if (next.truncated) terminate();
        });
        processHandle.stderr.on("data", (chunk) => {
          const next = boundedAppend(stderr, chunk, this.maxStderrBytes);
          stderr = next.value;
          stderrTruncated ||= next.truncated;
        });
        processHandle.on("error", (error) => {
          clearTimeout(timer);
          request.signal?.removeEventListener("abort", onAbort);
          finish(
            this.failure("codex_spawn_failed", error.message, true, stdout),
          );
        });
        processHandle.on("close", (exitCode) => {
          clearTimeout(timer);
          request.signal?.removeEventListener("abort", onAbort);
          if (cancelled) {
            finish({
              ...this.failure(
                "codex_cancelled",
                "Codex execution was cancelled",
                true,
                stdout,
              ),
              status: "cancelled",
            });
            return;
          }
          if (timedOut) {
            finish(
              this.failure(
                "codex_timeout",
                `Codex execution exceeded ${this.timeoutMs}ms`,
                true,
                stdout,
              ),
            );
            return;
          }
          if (stdoutTruncated || stderrTruncated) {
            finish(
              this.failure(
                "codex_output_limit",
                "Codex output exceeded the configured limit",
                true,
                stdout,
              ),
            );
            return;
          }
          if (exitCode !== 0) {
            finish(
              this.failure(
                "codex_failed",
                stderr || `Codex exited with code ${exitCode ?? "unknown"}`,
                true,
                stdout,
              ),
            );
            return;
          }
          const envelope = parseEnvelope(stdout);
          if (!envelope) {
            finish(
              this.failure(
                "invalid_protocol_output",
                "Codex did not return a Conclave protocol envelope",
                false,
                stdout,
              ),
            );
            return;
          }
          finish({
            status: "succeeded",
            output: JSON.stringify(envelope),
            rawOutput: stdout,
            usage: { inputTokens: null, outputTokens: null },
            evidenceArtifactIds: [],
          });
        });
      } catch (error) {
        clearTimeout(timer);
        request.signal?.removeEventListener("abort", onAbort);
        finish(
          this.failure(
            "codex_spawn_failed",
            error instanceof Error ? error.message : "Unable to start Codex",
            true,
            stdout,
          ),
        );
      }
    });
  }

  private failure(
    code: string,
    message: string,
    retryable: boolean,
    rawOutput: string | null = null,
  ): WorkerExecutionResult {
    return {
      status: "failed",
      output: null,
      rawOutput,
      usage: { inputTokens: null, outputTokens: null },
      evidenceArtifactIds: [],
      error: { code, message, retryable },
    };
  }
}
