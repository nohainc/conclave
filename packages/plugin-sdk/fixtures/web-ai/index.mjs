import process from "node:process";
import readline from "node:readline";

export const manifest = {
  pluginId: "conclave.web-ai",
  version: "1.0.0",
  displayName: "Web / Cloud AI Worker Plugin Fixture",
  description:
    "Worker plugin fixture executing tasks via Cloud Connector Relay to web AI models",
  publisher: "conclave",
  channel: "stable",
  protocolVersion: "2.0",
  minimumAgentVersion: "0.2.0",
  supportedOS: ["macos", "linux", "windows"],
  supportedArchitecture: ["arm64", "x64"],
  roles: [
    "architect",
    "reviewer",
    "evaluator",
    "implementer",
    "researcher",
    "coder",
  ],
  capabilities: ["web_chat", "interactive_relay", "code_execution", "network"],
  permissions: ["network:outbound", "workspace:read", "workspace:write"],
  configurationSchema: {
    type: "object",
    properties: {
      relayUrl: { type: "string" },
      targetPlatform: { type: "string", default: "chatgpt_web" },
    },
  },
  secretSchema: {
    CONCLAVE_CONNECTOR_TOKEN: { type: "string" },
  },
  entrypoint: "index.mjs",
  billingModes: ["subscription", "local_compute", "free"],
  digest: "sha256-conclave-web-ai-fixture-digest",
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
  const config = input.config || {};
  const targetPlatform = config.targetPlatform || "chatgpt_web";
  const startedAt = new Date().toISOString();

  process.stdout.write(
    JSON.stringify({
      type: "progress",
      stage: "relaying",
      percent: 20,
      logChunk: `Relaying prompt to Web AI (${targetPlatform}) via Cloud Relay`,
      timestamp: startedAt,
    }) + "\n",
  );

  const finishedAt = new Date().toISOString();
  const output = {
    status: "completed",
    summary: `Executed ${input.role || "task"} via Web AI (${targetPlatform}) through Cloud relay`,
    output: {
      platform: targetPlatform,
      solution: `Web AI (${targetPlatform}) completed ${input.objective || "task"}`,
      status: "success",
    },
    findings: [],
    artifactIds: ["art-web-ai-response"],
    evidence: {
      observedAt: finishedAt,
      metrics: {
        targetPlatform,
        relayed: true,
      },
      logs: [
        `[WebAI Fixture] Relayed at ${startedAt}`,
        `[WebAI Fixture] Response received from ${targetPlatform} at ${finishedAt}`,
      ],
    },
  };

  process.stdout.write(
    JSON.stringify({
      type: "result",
      output,
    }) + "\n",
  );

  process.exit(0);
}

if (process.env.CONCLAVE_PLUGIN_CHILD_PROCESS === "true") {
  void runCli();
}
