import readline from "node:readline";
import {
  type WorkerPluginManifest,
  validateWorkerPluginManifest,
} from "./manifest.js";
import type {
  WorkerPluginInput,
  WorkerPluginContext,
  WorkerPluginOutput,
  WorkerPluginHandler,
} from "./types.js";

export interface WorkerPluginDefinition {
  readonly manifest: WorkerPluginManifest;
  readonly execute: WorkerPluginHandler;
}

export function defineWorkerPlugin(
  definition: WorkerPluginDefinition,
): WorkerPluginDefinition {
  validateWorkerPluginManifest(definition.manifest);

  // If this file is being run directly as a child process by the PluginProcessRunner
  if (process.env.CONCLAVE_PLUGIN_CHILD_PROCESS === "true") {
    void runPluginCli(definition);
  }

  return definition;
}

async function runPluginCli(definition: WorkerPluginDefinition): Promise<void> {
  const rl = readline.createInterface({
    input: process.stdin,
    terminal: false,
  });

  let inputData = "";
  for await (const line of rl) {
    inputData += line;
  }

  if (!inputData.trim()) {
    process.exit(0);
  }

  const payload = JSON.parse(inputData) as {
    input: WorkerPluginInput;
    workDir: string;
  };

  const abortController = new AbortController();
  process.on("SIGTERM", () =>
    abortController.abort(new Error("SIGTERM received")),
  );
  process.on("SIGINT", () =>
    abortController.abort(new Error("SIGINT received")),
  );

  const emittedArtifacts: string[] = [];
  const emittedFindings: unknown[] = [];

  const context: WorkerPluginContext = {
    workDir: payload.workDir,
    signal: abortController.signal,
    config: payload.input.config ?? {},
    secrets: payload.input.secrets ?? {},
    log(level, message, ctx) {
      const line = JSON.stringify({
        type: "log",
        level,
        message,
        context: ctx,
        timestamp: new Date().toISOString(),
      });
      process.stdout.write(`${line}\n`);
    },
    progress(stage, percent, logChunk) {
      const line = JSON.stringify({
        type: "progress",
        stage,
        percent,
        logChunk,
        timestamp: new Date().toISOString(),
      });
      process.stdout.write(`${line}\n`);
    },
    emitArtifact(id, artifactPath) {
      emittedArtifacts.push(id);
      const line = JSON.stringify({
        type: "artifact",
        artifactId: id,
        path: artifactPath,
        timestamp: new Date().toISOString(),
      });
      process.stdout.write(`${line}\n`);
    },
    emitFinding(finding) {
      emittedFindings.push(finding);
      const line = JSON.stringify({
        type: "finding",
        finding,
        timestamp: new Date().toISOString(),
      });
      process.stdout.write(`${line}\n`);
    },
  };

  try {
    const result = await definition.execute(payload.input, context);
    const combinedArtifacts = Array.from(
      new Set([...(result.artifactIds ?? []), ...emittedArtifacts]),
    );
    const combinedFindings = [...(result.findings ?? []), ...emittedFindings];

    const finalOutput: WorkerPluginOutput = {
      ...result,
      artifactIds: combinedArtifacts,
      findings: combinedFindings.length > 0 ? combinedFindings : undefined,
    };

    process.stdout.write(
      `${JSON.stringify({ type: "result", output: finalOutput })}\n`,
    );
    process.exit(0);
  } catch (err) {
    const errorOutput: WorkerPluginOutput = {
      status: "failed",
      summary: "Plugin execution threw an unhandled error",
      output: null,
      artifactIds: emittedArtifacts,
      error: {
        code: "PLUGIN_EXECUTION_ERROR",
        message: err instanceof Error ? err.message : String(err),
        retryable: false,
      },
    };
    process.stdout.write(
      `${JSON.stringify({ type: "result", output: errorOutput })}\n`,
    );
    process.exit(1);
  }
}
