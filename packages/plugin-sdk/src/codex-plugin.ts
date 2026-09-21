import { spawn as nodeSpawn, type ChildProcess } from "node:child_process";
import process from "node:process";
import {
  defineWorkerPlugin,
  type WorkerPluginDefinition,
} from "./define-plugin.js";
import type { WorkerPluginManifest } from "./manifest.js";
import type {
  WorkerPluginInput,
  WorkerPluginContext,
  WorkerPluginOutput,
} from "./types.js";

export const CODEX_PLUGIN_ID = "conclave.codex";
export const CODEX_PLUGIN_VERSION = "1.0.0";

export const codexWorkerManifest: WorkerPluginManifest = {
  pluginId: CODEX_PLUGIN_ID,
  version: CODEX_PLUGIN_VERSION,
  displayName: "OpenAI Codex CLI Worker Plugin",
  description:
    "Worker plugin executing coding and architectural tasks via local OpenAI Codex CLI",
  publisher: "conclave",
  channel: "stable",
  protocolVersion: "2.0",
  minimumAgentVersion: "0.2.0",
  supportedOS: ["macos", "linux", "windows"],
  supportedArchitecture: ["arm64", "x64"],
  roles: ["implementer", "coder", "reviewer", "architect"],
  capabilities: ["code_execution", "file_system", "git_ops"],
  permissions: ["workspace:read", "workspace:write", "process:spawn"],
  configurationSchema: {
    type: "object",
    properties: {
      executable: { type: "string", default: "codex" },
      args: { type: "array", items: { type: "string" } },
      maxStdoutBytes: { type: "number", default: 2000000 },
      maxStderrBytes: { type: "number", default: 512000 },
    },
  },
  secretSchema: {
    OPENAI_API_KEY: {
      type: "string",
      description: "OpenAI API Key for Codex CLI",
    },
  },
  entrypoint: "index.js",
  billingModes: ["subscription", "local_compute", "api_metered"],
  digest: "sha256-conclave-codex-plugin-v1-digest",
};

export interface CodexSpawnChild {
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

export type CodexSpawner = (
  executable: string,
  args: readonly string[],
  options: {
    cwd: string;
    env: Record<string, string>;
    shell: false;
    detached: boolean;
    windowsHide: boolean;
    stdio: ["ignore", "pipe", "pipe"];
  },
) => CodexSpawnChild;

function defaultCodexSpawn(
  executable: string,
  args: readonly string[],
  options: {
    cwd: string;
    env: Record<string, string>;
    shell: false;
    detached: boolean;
    windowsHide: boolean;
    stdio: ["ignore", "pipe", "pipe"];
  },
): ChildProcess {
  return nodeSpawn(
    executable,
    [...args],
    options as unknown as Parameters<typeof nodeSpawn>[2],
  ) as unknown as ChildProcess;
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

export function parseCodexEnvelope(output: string): {
  messageType?: string;
  payload?: Record<string, unknown>;
  raw?: unknown;
} | null {
  const candidates: unknown[] = [];

  // 1. Try whole output
  try {
    candidates.push(JSON.parse(output.trim()));
  } catch {
    // ignore
  }

  // 2. Extract markdown code blocks ```(?:json)?([\s\S]*?)```
  const fenceMatches = output.matchAll(/```(?:json)?\s*([\s\S]*?)```/gi);
  for (const match of fenceMatches) {
    if (match[1]) {
      try {
        candidates.push(JSON.parse(match[1].trim()));
      } catch {
        // ignore
      }
    }
  }

  // 3. Extract JSON from first { to last }
  const firstBrace = output.indexOf("{");
  const lastBrace = output.lastIndexOf("}");
  if (firstBrace !== -1 && lastBrace > firstBrace) {
    try {
      candidates.push(JSON.parse(output.slice(firstBrace, lastBrace + 1)));
    } catch {
      // ignore
    }
  }

  // 4. Line-by-line candidate parsing
  const lines = output
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);

  for (const line of lines) {
    const withoutFence = line.replace(/^```(?:json)?\s*|```$/g, "");
    try {
      candidates.push(JSON.parse(withoutFence));
    } catch {
      // ignore non-json line
    }
  }

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
        raw: value,
      };
    }
    if (typeof value.result === "string") {
      const nested = parseCodexEnvelope(value.result);
      if (nested) return nested;
    }
    // Standard structured object without messageType wrapper
    if (value.status || value.summary || value.output) {
      return {
        messageType: "ImplementationResult",
        payload: value,
        raw: value,
      };
    }
  }
  return null;
}

export function buildCodexPrompt(input: WorkerPluginInput): string {
  return [
    "You are a Conclave local implementation agent.",
    "Work only inside the repository working directory provided by the runtime.",
    "Return exactly one JSON object with this shape and no prose:",
    '{"messageType":"ImplementationResult","payload":{"status":"completed","summary":"...","output":{...}}}',
    "The payload must be a valid Conclave protocol result. Describe proposed file operations explicitly; the runtime records and applies only approved operations.",
    `Objective:\n${input.objective}`,
    `Assigned Role:\n${input.role}`,
    input.input ? `Task Input:\n${JSON.stringify(input.input, null, 2)}` : "",
    input.contextArtifactIds && input.contextArtifactIds.length > 0
      ? `Context Artifacts:\n${JSON.stringify(input.contextArtifactIds)}`
      : "",
    input.repository
      ? `Repository:\n${JSON.stringify(input.repository, null, 2)}`
      : "",
  ]
    .filter(Boolean)
    .join("\n\n");
}

export async function executeCodexWorker(
  input: WorkerPluginInput,
  context: WorkerPluginContext,
  customSpawner?: CodexSpawner,
): Promise<WorkerPluginOutput> {
  const startedAt = new Date().toISOString();
  const config = context.config ?? {};
  const executable =
    typeof config.executable === "string" ? config.executable : "codex";
  const args = Array.isArray(config.args)
    ? (config.args as string[])
    : ["exec", "--json", "--full-auto"];
  const maxStdoutBytes =
    typeof config.maxStdoutBytes === "number"
      ? config.maxStdoutBytes
      : 2_000_000;
  const maxStderrBytes =
    typeof config.maxStderrBytes === "number" ? config.maxStderrBytes : 512_000;
  const timeoutMs = input.timeoutMs || 15 * 60_000;

  context.log(
    "info",
    `Starting Codex CLI worker execution for role '${input.role}'`,
    {
      objective: input.objective,
      executable,
      workDir: context.workDir,
    },
  );

  context.progress("init", 10, "Preparing Codex CLI execution context");

  const prompt = buildCodexPrompt(input);
  const spawnFn =
    customSpawner ?? (defaultCodexSpawn as unknown as CodexSpawner);

  const env: Record<string, string> = {
    ...(process.env as Record<string, string>),
    ...(context.secrets ?? {}),
  };

  return new Promise<WorkerPluginOutput>((resolve) => {
    let stdout = "";
    let stderr = "";
    let stdoutTruncated = false;
    let stderrTruncated = false;
    let timedOut = false;
    let cancelled = false;
    let settled = false;

    const finish = (result: WorkerPluginOutput) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      context.signal.removeEventListener("abort", onAbort);
      resolve(result);
    };

    const terminate = () => {
      if (!child) return;
      if (process.platform !== "win32" && child.pid) {
        try {
          process.kill(-child.pid, "SIGTERM");
          return;
        } catch {
          // fallback
        }
      }
      child.kill("SIGTERM");
    };

    const timer = setTimeout(() => {
      timedOut = true;
      context.log("warn", `Codex execution timed out after ${timeoutMs}ms`);
      terminate();
    }, timeoutMs);

    const onAbort = () => {
      cancelled = true;
      context.log("warn", "Codex execution cancelled via AbortSignal");
      terminate();
    };
    context.signal.addEventListener("abort", onAbort, { once: true });

    let child: CodexSpawnChild | undefined;
    try {
      context.progress(
        "executing_cli",
        30,
        `Spawning Codex CLI (${executable})`,
      );

      child = spawnFn(executable, [...args, prompt], {
        cwd: context.workDir,
        env,
        shell: false,
        detached: process.platform !== "win32",
        windowsHide: true,
        stdio: ["ignore", "pipe", "pipe"],
      });

      child.stdout.on("data", (chunk: Buffer) => {
        const next = boundedAppend(stdout, chunk, maxStdoutBytes);
        stdout = next.value;
        stdoutTruncated ||= next.truncated;
        if (next.truncated) {
          terminate();
        }
      });

      child.stderr.on("data", (chunk: Buffer) => {
        const next = boundedAppend(stderr, chunk, maxStderrBytes);
        stderr = next.value;
        stderrTruncated ||= next.truncated;
      });

      child.on("error", (error: Error) => {
        context.log("error", `Codex process spawn error: ${error.message}`);
        finish({
          status: "failed",
          summary: `Failed to spawn Codex CLI: ${error.message}`,
          output: null,
          artifactIds: [],
          error: {
            code: "CODEX_SPAWN_FAILED",
            message: error.message,
            retryable: true,
          },
        });
      });

      child.on("close", (exitCode: number | null) => {
        const completedAt = new Date().toISOString();

        if (cancelled) {
          finish({
            status: "failed",
            summary: "Codex CLI execution was cancelled",
            output: null,
            artifactIds: [],
            error: {
              code: "CODEX_CANCELLED",
              message: "Execution was aborted by host request",
              retryable: true,
            },
          });
          return;
        }

        if (timedOut) {
          finish({
            status: "failed",
            summary: `Codex CLI execution exceeded timeout of ${timeoutMs}ms`,
            output: null,
            artifactIds: [],
            error: {
              code: "CODEX_TIMEOUT",
              message: `Timeout exceeded ${timeoutMs}ms`,
              retryable: true,
            },
          });
          return;
        }

        if (stdoutTruncated || stderrTruncated) {
          finish({
            status: "failed",
            summary: "Codex output exceeded maximum configured byte limit",
            output: null,
            artifactIds: [],
            error: {
              code: "CODEX_OUTPUT_LIMIT",
              message: "Output buffer limit reached",
              retryable: false,
            },
          });
          return;
        }

        if (exitCode !== 0) {
          finish({
            status: "failed",
            summary:
              stderr.trim() ||
              `Codex CLI exited with status ${exitCode ?? "unknown"}`,
            output: null,
            artifactIds: [],
            error: {
              code: "CODEX_PROCESS_FAILED",
              message: stderr.trim() || `Process exited with code ${exitCode}`,
              retryable: exitCode === 137 || exitCode === 143,
            },
          });
          return;
        }

        context.progress(
          "parsing_output",
          85,
          "Parsing Codex structured response",
        );
        const parsed = parseCodexEnvelope(stdout);

        if (!parsed || !parsed.payload) {
          finish({
            status: "failed",
            summary: "Codex did not return a valid structured JSON envelope",
            output: { rawStdout: stdout },
            artifactIds: [],
            error: {
              code: "INVALID_PROTOCOL_OUTPUT",
              message: "Unable to parse JSON protocol result from Codex stdout",
              retryable: false,
            },
          });
          return;
        }

        context.progress(
          "completed",
          100,
          "Codex execution completed successfully",
        );

        const findings = Array.isArray(parsed.payload.findings)
          ? parsed.payload.findings
          : [];
        for (const f of findings) {
          context.emitFinding(f);
        }

        const artifactIds = Array.isArray(parsed.payload.artifactIds)
          ? (parsed.payload.artifactIds as string[])
          : [];

        finish({
          status: "completed",
          summary:
            typeof parsed.payload.summary === "string"
              ? parsed.payload.summary
              : `Codex successfully completed '${input.objective}'`,
          output: parsed.payload,
          artifactIds,
          findings: findings.length > 0 ? findings : undefined,
          evidence: {
            observedAt: completedAt,
            metrics: {
              stdoutBytes: Buffer.byteLength(stdout, "utf8"),
              stderrBytes: Buffer.byteLength(stderr, "utf8"),
              exitCode: 0,
            },
            logs: [
              `[${startedAt}] Codex spawned (${executable})`,
              `[${completedAt}] Codex finished successfully with exit code 0`,
            ],
          },
        });
      });
    } catch (err) {
      finish({
        status: "failed",
        summary: `Codex invocation threw exception: ${err instanceof Error ? err.message : String(err)}`,
        output: null,
        artifactIds: [],
        error: {
          code: "CODEX_INVOCATION_ERROR",
          message: err instanceof Error ? err.message : String(err),
          retryable: false,
        },
      });
    }
  });
}

export const codexWorkerDefinition: WorkerPluginDefinition = defineWorkerPlugin(
  {
    manifest: codexWorkerManifest,
    execute: executeCodexWorker,
  },
);
