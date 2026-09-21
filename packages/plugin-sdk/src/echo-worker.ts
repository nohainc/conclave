import fs from "node:fs";
import path from "node:path";
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

export const ECHO_WORKER_PLUGIN_ID = "conclave.echo-worker";
export const ECHO_WORKER_VERSION = "1.0.0";

export const echoWorkerManifest: WorkerPluginManifest = {
  pluginId: ECHO_WORKER_PLUGIN_ID,
  version: ECHO_WORKER_VERSION,
  displayName: "Echo Test Worker",
  description:
    "Deterministic test worker for end-to-end cloud-agent-worker verification",
  publisher: "conclave",
  channel: "stable",
  protocolVersion: "2.0",
  minimumAgentVersion: "0.2.0",
  supportedOS: ["macos", "linux", "windows"],
  supportedArchitecture: ["arm64", "x64"],
  roles: [
    "implementer",
    "reviewer",
    "tester",
    "evaluator",
    "architect",
    "coder",
  ],
  capabilities: ["code_execution", "file_system"],
  permissions: ["workspace:read", "workspace:write"],
  configurationSchema: {
    type: "object",
    properties: {
      echoPrefix: { type: "string" },
      emitTestArtifact: { type: "boolean" },
      simulateDelayMs: { type: "number" },
    },
  },
  secretSchema: {},
  entrypoint: "index.js",
  billingModes: ["free", "local_compute"] as const,
  digest: "sha256-echo-test-worker-manifest-digest",
};

export async function executeEchoWorker(
  input: WorkerPluginInput,
  context: WorkerPluginContext,
): Promise<WorkerPluginOutput> {
  const startedAt = new Date().toISOString();
  const config = context.config ?? {};
  const echoPrefix =
    typeof config.echoPrefix === "string" ? config.echoPrefix : "ECHO:";
  const emitTestArtifact = Boolean(config.emitTestArtifact ?? true);
  const simulateDelayMs =
    typeof config.simulateDelayMs === "number" ? config.simulateDelayMs : 10;

  context.log("info", `Echo worker starting objective: ${input.objective}`, {
    role: input.role,
    workDir: context.workDir,
  });

  context.progress(
    "init",
    10,
    "Initializing deterministic test worker environment",
  );

  if (simulateDelayMs > 0) {
    await new Promise((resolve) => setTimeout(resolve, simulateDelayMs));
  }

  context.progress("processing", 50, `Echoing payload for role ${input.role}`);

  const emittedArtifacts: string[] = [];
  const emittedFindings: unknown[] = [];

  // Write a deterministic file artifact to workspace if enabled
  if (emitTestArtifact && context.workDir && fs.existsSync(context.workDir)) {
    const artifactFilename = "echo-evidence.txt";
    const artifactPath = path.join(context.workDir, artifactFilename);
    const content = `Echo Worker Evidence\nObjective: ${input.objective}\nRole: ${input.role}\nTimestamp: ${startedAt}\nPayload: ${JSON.stringify(input.input ?? {})}\n`;
    fs.writeFileSync(artifactPath, content, "utf-8");

    const artifactId = `artifact-echo-${Date.now()}`;
    context.emitArtifact(artifactId, artifactPath);
    emittedArtifacts.push(artifactId);
  }

  const finding = {
    id: `finding-echo-${Date.now()}`,
    type: "deterministic_verification",
    title: `Echo worker verified objective '${input.objective}'`,
    severity: "info",
    details: {
      role: input.role,
      inputKeys: Object.keys(input.input ?? {}),
    },
  };
  context.emitFinding(finding);
  emittedFindings.push(finding);

  context.progress(
    "completed",
    100,
    "Deterministic execution completed successfully",
  );

  const completedAt = new Date().toISOString();

  return {
    status: "completed",
    summary: `${echoPrefix} Successfully executed '${input.objective}' for role '${input.role}'`,
    output: {
      echo: true,
      deterministicStatus: "SUCCESS",
      receivedObjective: input.objective,
      receivedRole: input.role,
      receivedInput: input.input ?? {},
      appliedConfig: config,
      repository: input.repository ?? null,
      executedInWorkDir: context.workDir,
    },
    artifactIds: emittedArtifacts,
    findings: emittedFindings,
    evidence: {
      observedAt: completedAt,
      metrics: {
        executionDurationMs: simulateDelayMs,
        artifactsCreated: emittedArtifacts.length,
        findingsCount: emittedFindings.length,
      },
      logs: [
        `[${startedAt}] Echo worker started`,
        `[${completedAt}] Echo worker finished`,
      ],
    },
  };
}

export const echoWorkerDefinition: WorkerPluginDefinition = defineWorkerPlugin({
  manifest: echoWorkerManifest,
  execute: executeEchoWorker,
});
