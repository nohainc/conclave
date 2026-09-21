import process from "node:process";
import readline from "node:readline";

export const manifest = {
  pluginId: "conclave.claude-code",
  version: "1.0.0",
  displayName: "Anthropic Claude Code CLI Worker Plugin",
  description:
    "Worker plugin executing coding and review tasks via local Claude Code CLI",
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
      executable: { type: "string", default: "claude" },
      args: { type: "array", items: { type: "string" } },
    },
  },
  secretSchema: {
    ANTHROPIC_API_KEY: { type: "string" },
  },
  entrypoint: "index.mjs",
  billingModes: ["subscription", "local_compute", "api_metered"],
  digest: "sha256-conclave-claude-fixture-digest",
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

  const startedAt = new Date().toISOString();

  process.stdout.write(
    JSON.stringify({
      type: "progress",
      stage: "init",
      percent: 10,
      logChunk: "Initializing Claude Code worker execution context",
      timestamp: startedAt,
    }) + "\n",
  );

  process.stdout.write(
    JSON.stringify({
      type: "progress",
      stage: "executing_cli",
      percent: 50,
      logChunk: `Claude Code processing objective: ${input.objective || "task"}`,
      timestamp: new Date().toISOString(),
    }) + "\n",
  );

  const completedAt = new Date().toISOString();

  const finalOutput = {
    status: "completed",
    summary: `Claude Code successfully completed '${input.objective}' for role '${input.role}'`,
    output: {
      provider: "anthropic-claude",
      objective: input.objective,
      role: input.role,
      workDir,
      reviewFindings: [],
      executionStatus: "SUCCESS",
    },
    artifactIds: input.contextArtifactIds || [],
    findings: [
      {
        id: `finding-claude-${Date.now()}`,
        type: "review_summary",
        title: `Claude Code evaluated ${input.objective}`,
        severity: "info",
      },
    ],
    evidence: {
      observedAt: completedAt,
      metrics: {
        durationMs: 12,
        exitCode: 0,
      },
      logs: [
        `[${startedAt}] Claude CLI simulated start`,
        `[${completedAt}] Claude CLI simulated completion`,
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
