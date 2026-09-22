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

export const WEB_AI_PLUGIN_ID = "conclave.web-ai";
export const WEB_AI_PLUGIN_VERSION = "1.0.0";

export const webAiWorkerManifest: WorkerPluginManifest = {
  pluginId: WEB_AI_PLUGIN_ID,
  version: WEB_AI_PLUGIN_VERSION,
  displayName: "Web / Cloud AI Worker Plugin",
  description:
    "Worker plugin executing tasks by relaying interactive prompts to ChatGPT, Claude, or Gemini web sessions via Cloud Connector Relay",
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
  permissions: [
    "network:outbound",
    "workspace:read",
    "workspace:write",
    "credentials:read",
  ],
  configurationSchema: {
    type: "object",
    properties: {
      relayUrl: {
        type: "string",
        default: "https://app.conclaveax.com/api/connector",
      },
      targetPlatform: {
        type: "string",
        enum: ["chatgpt_web", "claude_web", "gemini_web", "custom"],
        default: "chatgpt_web",
      },
      pollIntervalMs: { type: "number", default: 200 },
      timeoutMs: { type: "number", default: 60000 },
    },
  },
  secretSchema: {
    CONCLAVE_CONNECTOR_TOKEN: {
      type: "string",
      description: "Authentication token for Cloud connector relay",
    },
  },
  entrypoint: "index.js",
  billingModes: ["subscription", "local_compute", "free"],
  digest: "sha256-conclave-web-ai-plugin-v1-digest",
};

export type WebAiFetchTransport = (
  input: RequestInfo | URL,
  init?: RequestInit,
) => Promise<Response>;

export function buildWebAiPrompt(input: WorkerPluginInput): string {
  const sections: string[] = [
    `# Task Assignment: ${input.role.toUpperCase()}`,
    `Objective: ${input.objective}`,
  ];

  if (input.input && Object.keys(input.input).length > 0) {
    sections.push(
      `Input:\n\`\`\`json\n${JSON.stringify(input.input, null, 2)}\n\`\`\``,
    );
  }

  if (input.contextArtifactIds && input.contextArtifactIds.length > 0) {
    sections.push(`Context Artifacts: ${input.contextArtifactIds.join(", ")}`);
  }

  sections.push(
    "Instructions:",
    "Provide structured JSON output with:",
    '{"status":"completed","summary":"...","output":{...},"findings":[]}',
  );

  return sections.join("\n\n");
}

export async function executeWebAiWorker(
  input: WorkerPluginInput,
  context: WorkerPluginContext,
  customFetch?: WebAiFetchTransport,
): Promise<WorkerPluginOutput> {
  const startedAt = new Date().toISOString();
  const fetchImpl = customFetch || globalThis.fetch;

  const config = (input.config || {}) as {
    relayUrl?: string;
    targetPlatform?: string;
    pollIntervalMs?: number;
    timeoutMs?: number;
  };

  const relayUrl = (
    config.relayUrl || "https://app.conclaveax.com/api/connector"
  ).replace(/\/$/, "");

  const sessionToken =
    input.secrets?.CONCLAVE_CONNECTOR_TOKEN ||
    process.env.CONCLAVE_CONNECTOR_TOKEN;

  if (!sessionToken) {
    return {
      status: "failed",
      summary: "Web AI connector authentication is unavailable",
      output: null,
      artifactIds: [],
      error: {
        code: "CONNECTOR_AUTH_REQUIRED",
        message:
          "CONCLAVE_CONNECTOR_TOKEN must be configured on the Agent host",
        retryable: false,
      },
    };
  }

  const targetPlatform = config.targetPlatform || "chatgpt_web";
  const pollIntervalMs = config.pollIntervalMs || 200;
  const timeoutMs = input.timeoutMs || config.timeoutMs || 30_000;

  context.log(
    "info",
    `Relaying task to Web AI (${targetPlatform}) via Cloud Relay: ${relayUrl}`,
  );

  // 1. Format interactive prompt payload
  const formattedPrompt = buildWebAiPrompt(input);
  const taskId =
    typeof input.input?.taskId === "string"
      ? input.input.taskId
      : `task-web-${Date.now()}`;

  // 2. Post task to Cloud connector relay
  const registerPayload = {
    taskId,
    role: input.role,
    objective: input.objective,
    targetPlatform,
    prompt: formattedPrompt,
    input: input.input || {},
    contextArtifactIds: input.contextArtifactIds || [],
    registeredAt: startedAt,
  };

  const registerRes = await fetchImpl(`${relayUrl}/tasks/register`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${sessionToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(registerPayload),
    signal: context.signal,
  });

  if (!registerRes.ok && registerRes.status !== 404) {
    const errorText = await registerRes.text();
    return {
      status: "failed",
      summary: `Failed to register task with Cloud connector relay: ${errorText}`,
      output: null,
      artifactIds: [],
      error: {
        code: "CONNECTOR_RELAY_ERROR",
        message: `Cloud connector relay returned HTTP ${registerRes.status}: ${errorText}`,
        retryable: registerRes.status >= 500,
      },
    };
  }

  context.progress("Task queued in Cloud connector relay", 25);

  // 3. Poll Cloud relay for task results from web AI session
  const startTime = Date.now();
  while (Date.now() - startTime < timeoutMs) {
    if (context.signal.aborted) {
      throw new Error("Task execution was aborted by signal");
    }

    const pollRes = await fetchImpl(`${relayUrl}/tasks/${taskId}/status`, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${sessionToken}`,
      },
      signal: context.signal,
    });

    if (pollRes.ok) {
      const pollData = (await pollRes.json()) as {
        status: "queued" | "claimed" | "completed" | "failed";
        result?: Record<string, unknown> | null;
        summary?: string;
        findings?: unknown[];
        artifactIds?: string[];
        error?: { code: string; message: string; retryable?: boolean };
        progress?: number;
      };

      if (pollData.status === "completed") {
        context.progress("Web AI result received from relay", 100);
        const finishedAt = new Date().toISOString();

        return {
          status: "completed",
          summary:
            pollData.summary ||
            `Task completed via Web AI (${targetPlatform}) through Cloud relay`,
          output: pollData.result || { success: true },
          findings: pollData.findings || [],
          artifactIds: pollData.artifactIds || [],
          evidence: {
            observedAt: finishedAt,
            metrics: {
              targetPlatform,
              pollDurationMs: Date.now() - startTime,
              relayedVia: relayUrl,
            },
            logs: [
              `[WebAI] Task registered at ${startedAt}`,
              `[WebAI] Response received from ${targetPlatform} at ${finishedAt}`,
            ],
          },
        };
      }

      if (pollData.status === "failed") {
        return {
          status: "failed",
          summary: pollData.error?.message || "Web AI session reported failure",
          output: null,
          artifactIds: [],
          error: {
            code: pollData.error?.code || "WEB_AI_EXECUTION_FAILED",
            message:
              pollData.error?.message || "Web AI session reported failure",
            retryable: pollData.error?.retryable ?? false,
          },
        };
      }

      if (pollData.status === "claimed") {
        context.progress(
          `Web AI session active on ${targetPlatform}`,
          pollData.progress || 50,
        );
      }
    }

    // Wait for next poll cycle
    await new Promise((resolve) => setTimeout(resolve, pollIntervalMs));
  }

  return {
    status: "failed",
    summary: `Timed out after ${timeoutMs}ms waiting for Web AI response from Cloud relay`,
    output: null,
    artifactIds: [],
    error: {
      code: "CONNECTOR_RELAY_TIMEOUT",
      message: `Timed out after ${timeoutMs}ms waiting for Web AI response from Cloud relay`,
      retryable: true,
    },
  };
}

export const webAiWorkerDefinition: WorkerPluginDefinition = defineWorkerPlugin(
  {
    manifest: webAiWorkerManifest,
    execute: executeWebAiWorker,
  },
);
