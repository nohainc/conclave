import readline from "node:readline";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { setTimeout as sleep } from "node:timers/promises";

export const manifest = {
  pluginId: "conclave.echo-worker",
  version: "1.0.0",
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
  entrypoint: "index.mjs",
  billingModes: ["free", "local_compute"],
  digest: "sha256-echo-test-worker-fixture-digest",
};

export async function runCli() {
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

  const payload = JSON.parse(inputData);
  const input = payload.input || {};
  const workDir = payload.workDir || process.cwd();
  const config = input.config || {};
  const echoPrefix =
    typeof config.echoPrefix === "string" ? config.echoPrefix : "ECHO:";
  const emitTestArtifact = Boolean(config.emitTestArtifact ?? true);
  const simulateDelayMs =
    typeof config.simulateDelayMs === "number" ? config.simulateDelayMs : 5;

  const startedAt = new Date().toISOString();

  // 1. Progress init
  process.stdout.write(
    JSON.stringify({
      type: "progress",
      stage: "init",
      percent: 10,
      logChunk: "Initializing deterministic echo worker",
      timestamp: startedAt,
    }) + "\n",
  );

  if (simulateDelayMs > 0) {
    await sleep(simulateDelayMs);
  }

  // 2. Progress processing
  process.stdout.write(
    JSON.stringify({
      type: "progress",
      stage: "processing",
      percent: 50,
      logChunk: `Echoing payload for role ${input.role || "unknown"}`,
      timestamp: new Date().toISOString(),
    }) + "\n",
  );

  const emittedArtifacts = [];
  const emittedFindings = [];

  // 3. Artifact emission
  if (emitTestArtifact && workDir && fs.existsSync(workDir)) {
    const artifactFilename = "echo-evidence.txt";
    const artifactPath = path.join(workDir, artifactFilename);
    const content = `Echo Worker Evidence\nObjective: ${input.objective}\nRole: ${input.role}\nTimestamp: ${startedAt}\nPayload: ${JSON.stringify(input.input || {})}\n`;
    fs.writeFileSync(artifactPath, content, "utf-8");

    const artifactId = `artifact-echo-${Date.now()}`;
    emittedArtifacts.push(artifactId);
    process.stdout.write(
      JSON.stringify({
        type: "artifact",
        artifactId,
        path: artifactPath,
        timestamp: new Date().toISOString(),
      }) + "\n",
    );
  }

  // 4. Finding emission
  const finding = {
    id: `finding-echo-${Date.now()}`,
    type: "deterministic_verification",
    title: `Echo worker verified objective '${input.objective}'`,
    severity: "info",
    details: {
      role: input.role,
      inputKeys: Object.keys(input.input || {}),
    },
  };
  emittedFindings.push(finding);
  process.stdout.write(
    JSON.stringify({
      type: "finding",
      finding,
      timestamp: new Date().toISOString(),
    }) + "\n",
  );

  // 5. Progress completed
  const completedAt = new Date().toISOString();
  process.stdout.write(
    JSON.stringify({
      type: "progress",
      stage: "completed",
      percent: 100,
      logChunk: "Deterministic execution completed successfully",
      timestamp: completedAt,
    }) + "\n",
  );

  // 6. Result
  const finalOutput = {
    status: "completed",
    summary: `${echoPrefix} Successfully executed '${input.objective}' for role '${input.role}'`,
    output: {
      echo: true,
      deterministicStatus: "SUCCESS",
      receivedObjective: input.objective,
      receivedRole: input.role,
      receivedInput: input.input || {},
      appliedConfig: config,
      repository: input.repository || null,
      executedInWorkDir: workDir,
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

  process.stdout.write(
    JSON.stringify({
      type: "result",
      output: finalOutput,
    }) + "\n",
  );

  process.exit(0);
}

if (process.env.CONCLAVE_PLUGIN_CHILD_PROCESS === "true") {
  void runCli();
}
