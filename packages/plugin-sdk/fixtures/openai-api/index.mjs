import process from "node:process";
import readline from "node:readline";

export const manifest = {
  pluginId: "conclave.openai-api",
  version: "1.0.0",
  displayName: "OpenAI Chat/Responses API Worker Plugin",
  description:
    "Worker plugin executing architectural and coding tasks via OpenAI API calls",
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
      model: { type: "string", default: "gpt-4o" },
      endpoint: {
        type: "string",
        default: "https://api.openai.com/v1/chat/completions",
      },
    },
  },
  secretSchema: {
    OPENAI_API_KEY: { type: "string" },
  },
  entrypoint: "index.mjs",
  billingModes: ["api_metered", "subscription", "local_compute"],
  digest: "sha256-conclave-openai-api-fixture-digest",
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
  const model = config.model || "gpt-4o";

  const startedAt = new Date().toISOString();

  process.stdout.write(
    JSON.stringify({
      type: "progress",
      stage: "init",
      percent: 10,
      logChunk: `Preparing OpenAI API request for ${model}`,
      timestamp: startedAt,
    }) + "\n",
  );

  process.stdout.write(
    JSON.stringify({
      type: "progress",
      stage: "calling_api",
      percent: 40,
      logChunk: `Sending request to OpenAI API (${model})`,
      timestamp: new Date().toISOString(),
    }) + "\n",
  );

  const completedAt = new Date().toISOString();

  const finalOutput = {
    status: "completed",
    summary: `OpenAI (${model}) successfully completed '${input.objective}' for role '${input.role}'`,
    output: {
      provider: "openai-api",
      model,
      objective: input.objective,
      role: input.role,
      workDir,
      resultText: `Generated response from ${model} for ${input.objective}`,
      executionStatus: "SUCCESS",
    },
    artifactIds: input.contextArtifactIds || [],
    findings: [
      {
        id: `finding-openai-api-${Date.now()}`,
        type: "api_generation",
        title: `OpenAI ${model} generated task output`,
        severity: "info",
      },
    ],
    evidence: {
      observedAt: completedAt,
      metrics: {
        model,
        inputTokens: 120,
        outputTokens: 85,
        totalTokens: 205,
      },
      logs: [
        `[${startedAt}] OpenAI API request initiated (${model})`,
        `[${completedAt}] OpenAI API response processed successfully (205 tokens)`,
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
