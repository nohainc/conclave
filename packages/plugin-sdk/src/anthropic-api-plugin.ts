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
import { parseCodexEnvelope } from "./codex-plugin.js";
import type { FetchTransport } from "./openai-api-plugin.js";

export const ANTHROPIC_API_PLUGIN_ID = "conclave.anthropic-api";
export const ANTHROPIC_API_PLUGIN_VERSION = "1.0.0";

export const anthropicApiWorkerManifest: WorkerPluginManifest = {
  pluginId: ANTHROPIC_API_PLUGIN_ID,
  version: ANTHROPIC_API_PLUGIN_VERSION,
  displayName: "Anthropic Claude Messages API Worker Plugin",
  description:
    "Worker plugin executing architectural, coding, and review tasks via direct Anthropic Claude Messages API calls from the host Agent",
  publisher: "conclave",
  channel: "stable",
  protocolVersion: "2.0",
  minimumAgentVersion: "0.2.0",
  supportedOS: ["macos", "linux", "windows"],
  supportedArchitecture: ["arm64", "x64"],
  roles: ["architect", "reviewer", "evaluator", "implementer", "coder"],
  capabilities: ["code_execution", "network"],
  permissions: [
    "network:outbound",
    "workspace:read",
    "workspace:write",
    "credentials:read",
  ],
  configurationSchema: {
    type: "object",
    properties: {
      model: { type: "string", default: "claude-3-7-sonnet-20250219" },
      endpoint: {
        type: "string",
        default: "https://api.anthropic.com/v1/messages",
      },
      temperature: { type: "number", default: 0.2 },
      maxTokens: { type: "number", default: 4096 },
    },
  },
  secretSchema: {
    ANTHROPIC_API_KEY: {
      type: "string",
      description: "Anthropic API Key for direct Claude API execution",
    },
  },
  entrypoint: "index.js",
  billingModes: ["api_metered", "subscription", "local_compute"],
  digest: "sha256-conclave-anthropic-api-plugin-v1-digest",
};

export function buildAnthropicMessagesPayload(input: WorkerPluginInput): {
  system: string;
  messages: Array<{ role: "user" | "assistant"; content: string }>;
} {
  const system = [
    "You are a Conclave AI worker running through a process-isolated local Agent plugin.",
    "Return exactly one JSON object with this shape and no prose:",
    '{"status":"completed","summary":"...","output":{...},"findings":[]}',
    `Assigned Role: ${input.role}`,
    `Task Objective: ${input.objective}`,
  ].join("\n");

  const userContent = [
    input.input ? `Input Data:\n${JSON.stringify(input.input, null, 2)}` : "",
    input.contextArtifactIds && input.contextArtifactIds.length > 0
      ? `Context Artifacts:\n${JSON.stringify(input.contextArtifactIds)}`
      : "",
    input.repository
      ? `Repository Info:\n${JSON.stringify(input.repository, null, 2)}`
      : "",
  ]
    .filter(Boolean)
    .join("\n\n");

  return {
    system,
    messages: [{ role: "user", content: userContent || input.objective }],
  };
}

export async function executeAnthropicApiWorker(
  input: WorkerPluginInput,
  context: WorkerPluginContext,
  customFetch?: FetchTransport,
): Promise<WorkerPluginOutput> {
  const startedAt = new Date().toISOString();
  const config = context.config ?? {};
  const model =
    typeof config.model === "string"
      ? config.model
      : "claude-3-7-sonnet-20250219";
  const endpoint =
    typeof config.endpoint === "string"
      ? config.endpoint
      : "https://api.anthropic.com/v1/messages";
  const temperature =
    typeof config.temperature === "number" ? config.temperature : 0.2;
  const maxTokens =
    typeof config.maxTokens === "number" ? config.maxTokens : 4096;
  const fetchFn = customFetch ?? fetch;

  const apiKey =
    context.secrets.ANTHROPIC_API_KEY ||
    (process.env.ANTHROPIC_API_KEY as string | undefined);

  if (!apiKey) {
    return {
      status: "failed",
      summary: "Missing ANTHROPIC_API_KEY in Agent local secrets",
      output: null,
      artifactIds: [],
      error: {
        code: "MISSING_API_KEY",
        message:
          "Anthropic API key was not found in local worker secrets or host environment",
        retryable: false,
      },
    };
  }

  context.log(
    "info",
    `Starting Anthropic API worker for role '${input.role}'`,
    {
      model,
      endpoint,
      objective: input.objective,
    },
  );

  context.progress(
    "init",
    10,
    "Preparing Anthropic Messages API request envelope",
  );

  const { system, messages } = buildAnthropicMessagesPayload(input);
  const requestBody = {
    model,
    system,
    messages,
    temperature,
    max_tokens: maxTokens,
  };

  try {
    context.progress(
      "calling_api",
      40,
      `Calling Anthropic Claude API (${model})`,
    );

    const response = await fetchFn(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify(requestBody),
      signal: context.signal,
    });

    if (!response.ok) {
      const errText = await response.text();
      const isRetryable =
        response.status === 429 ||
        response.status === 500 ||
        response.status === 502 ||
        response.status === 503;

      return {
        status: "failed",
        summary: `Anthropic API returned HTTP status ${response.status}`,
        output: null,
        artifactIds: [],
        error: {
          code: `ANTHROPIC_HTTP_${response.status}`,
          message:
            errText || `HTTP request failed with status ${response.status}`,
          retryable: isRetryable,
        },
      };
    }

    context.progress(
      "parsing_response",
      80,
      "Parsing Anthropic Claude response",
    );

    const data = (await response.json()) as {
      id?: string;
      content?: Array<{ type?: string; text?: string }>;
      stop_reason?: string;
      usage?: {
        input_tokens?: number;
        output_tokens?: number;
      };
    };

    let rawContent = "";
    if (Array.isArray(data.content)) {
      for (const block of data.content) {
        if (block.type === "text" && typeof block.text === "string") {
          rawContent += block.text;
        }
      }
    }

    const parsedEnvelope = parseCodexEnvelope(rawContent);
    const completedAt = new Date().toISOString();
    const inputTokens = data.usage?.input_tokens ?? null;
    const outputTokens = data.usage?.output_tokens ?? null;

    const payload = parsedEnvelope?.payload ?? {
      status: "completed",
      summary: `Anthropic (${model}) completed task: ${input.objective}`,
      output: { text: rawContent },
    };

    const findings = Array.isArray(payload.findings) ? payload.findings : [];
    for (const f of findings) {
      context.emitFinding(f);
    }

    const artifactIds = Array.isArray(payload.artifactIds)
      ? (payload.artifactIds as string[])
      : [];

    context.progress(
      "completed",
      100,
      "Anthropic Claude API task completed successfully",
    );

    return {
      status: "completed",
      summary:
        typeof payload.summary === "string"
          ? payload.summary
          : `Anthropic (${model}) successfully completed '${input.objective}'`,
      output: payload,
      artifactIds,
      findings: findings.length > 0 ? findings : undefined,
      evidence: {
        observedAt: completedAt,
        metrics: {
          model,
          providerRequestId: data.id ?? null,
          inputTokens,
          outputTokens,
          totalTokens:
            inputTokens !== null && outputTokens !== null
              ? inputTokens + outputTokens
              : null,
          stopReason: data.stop_reason ?? null,
        },
        logs: [
          `[${startedAt}] Anthropic API request sent to ${endpoint} (${model})`,
          `[${completedAt}] Anthropic API response received (tokens: ${inputTokens ?? 0} in, ${outputTokens ?? 0} out)`,
        ],
      },
    };
  } catch (err: unknown) {
    const isAborted = context.signal.aborted;
    const errorMessage = err instanceof Error ? err.message : String(err);

    context.log("error", `Anthropic API execution error: ${errorMessage}`, {
      aborted: isAborted,
    });

    return {
      status: "failed",
      summary: isAborted
        ? "Anthropic API call was cancelled by host request"
        : `Anthropic API execution error: ${errorMessage}`,
      output: null,
      artifactIds: [],
      error: {
        code: isAborted
          ? "ANTHROPIC_REQUEST_CANCELLED"
          : "ANTHROPIC_EXECUTION_ERROR",
        message: errorMessage,
        retryable: isAborted,
      },
    };
  }
}

export const anthropicApiWorkerDefinition: WorkerPluginDefinition =
  defineWorkerPlugin({
    manifest: anthropicApiWorkerManifest,
    execute: executeAnthropicApiWorker,
  });
