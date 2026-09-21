import process from "node:process";
import readline from "node:readline";

export const manifest = {
  pluginId: "conclave.anthropic-api",
  version: "1.0.0",
  displayName: "Anthropic Claude Messages API Worker Plugin",
  description:
    "Worker plugin executing architectural and review tasks via Anthropic Claude Messages API calls",
  publisher: "conclave",
  channel: "stable",
  protocolVersion: "2.0",
  minimumAgentVersion: "0.2.0",
  supportedOS: ["macos", "linux", "windows"],
  supportedArchitecture: ["arm64", "x64"],
  roles: ["architect", "reviewer", "evaluator", "implementer", "coder"],
  capabilities: ["code_execution", "network"],
  permissions: ["network:outbound", "workspace:read", "workspace:write"],
  configurationSchema: {
    type: "object",
    properties: {
      model: { type: "string", default: "claude-3-7-sonnet-20250219" },
      endpoint: {
        type: "string",
        default: "https://api.anthropic.com/v1/messages",
      },
    },
  },
  secretSchema: {
    ANTHROPIC_API_KEY: { type: "string" },
  },
  entrypoint: "index.mjs",
  billingModes: ["api_metered", "subscription", "local_compute"],
  digest: "sha256-conclave-anthropic-api-fixture-digest",
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
  const model = config.model || "claude-3-7-sonnet-20250219";

  const startedAt = new Date().toISOString();

  process.stdout.write(
    JSON.stringify({
      type: "progress",
      stage: "init",
      percent: 10,
      logChunk: `Preparing Anthropic Claude API request for ${model}`,
      timestamp: startedAt,
    }) + "\n",
  );

  process.stdout.write(
    JSON.stringify({
      type: "progress",
      stage: "calling_api",
      percent: 40,
      logChunk: `Sending request to Anthropic Messages API (${model})`,
      timestamp: new Date().toISOString(),
    }) + "\n",
  );

  const completedAt = new Date().toISOString();

  const finalOutput = {
    status: "completed",
    summary: `Anthropic (${model}) successfully completed '${input.objective}' for role '${input.role}'`,
    output: {
      provider: "anthropic-api",
      model,
      objective: input.objective,
      role: input.role,
      workDir,
      resultText: `Generated response from Claude ${model} for ${input.objective}`,
      executionStatus: "SUCCESS",
    },
    artifactIds: input.contextArtifactIds || [],
    findings: [
      {
        id: `finding-anthropic-api-${Date.now()}`,
        type: "api_review",
        title: `Claude ${model} completed review analysis`,
        severity: "info",
      },
    ],
    evidence: {
      observedAt: completedAt,
      metrics: {
        model,
        inputTokens: 150,
        outputTokens: 110,
        totalTokens: 260,
      },
      logs: [
        `[${startedAt}] Anthropic API request initiated (${model})`,
        `[${completedAt}] Anthropic Messages API response received (260 tokens)`,
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
