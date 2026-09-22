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

export const OPENAI_API_PLUGIN_ID = "conclave.openai-api";
export const OPENAI_API_PLUGIN_VERSION = "1.0.0";

export const openaiApiWorkerManifest: WorkerPluginManifest = {
  pluginId: OPENAI_API_PLUGIN_ID,
  version: OPENAI_API_PLUGIN_VERSION,
  displayName: "OpenAI Chat/Responses API Worker Plugin",
  description:
    "Worker plugin executing architectural, coding, and review tasks via direct OpenAI API calls from the host Agent",
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
      model: { type: "string", default: "gpt-4o" },
      endpoint: {
        type: "string",
        default: "https://api.openai.com/v1/chat/completions",
      },
      temperature: { type: "number", default: 0.2 },
      maxTokens: { type: "number", default: 4096 },
      responseFormat: {
        type: "string",
        enum: ["json_object", "text"],
        default: "json_object",
      },
    },
  },
  secretSchema: {
    OPENAI_API_KEY: {
      type: "string",
      description: "OpenAI API Key for direct model API execution",
    },
  },
  entrypoint: "index.js",
  billingModes: ["api_metered", "subscription", "local_compute"],
  digest: "sha256-conclave-openai-api-plugin-v1-digest",
};

export type FetchTransport = (
  input: RequestInfo | URL,
  init?: RequestInit,
) => Promise<Response>;

export function buildOpenAIMessages(input: WorkerPluginInput): Array<{
  role: "system" | "user" | "assistant";
  content: string;
}> {
  const systemPrompt = [
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

  return [
    { role: "system", content: systemPrompt },
    { role: "user", content: userContent || input.objective },
  ];
}

export async function executeOpenAIApiWorker(
  input: WorkerPluginInput,
  context: WorkerPluginContext,
  customFetch?: FetchTransport,
): Promise<WorkerPluginOutput> {
  const startedAt = new Date().toISOString();
  const config = context.config ?? {};
  const model = typeof config.model === "string" ? config.model : "gpt-4o";
  const endpoint =
    typeof config.endpoint === "string"
      ? config.endpoint
      : "https://api.openai.com/v1/chat/completions";
  const temperature =
    typeof config.temperature === "number" ? config.temperature : 0.2;
  const maxTokens =
    typeof config.maxTokens === "number" ? config.maxTokens : 4096;
  const fetchFn = customFetch ?? fetch;

  const apiKey =
    context.secrets.OPENAI_API_KEY ||
    (process.env.OPENAI_API_KEY as string | undefined);

  if (!apiKey) {
    return {
      status: "failed",
      summary: "Missing OPENAI_API_KEY in Agent local secrets",
      output: null,
      artifactIds: [],
      error: {
        code: "MISSING_API_KEY",
        message:
          "OpenAI API key was not found in local worker secrets or host environment",
        retryable: false,
      },
    };
  }

  context.log("info", `Starting OpenAI API worker for role '${input.role}'`, {
    model,
    endpoint,
    objective: input.objective,
  });

  context.progress("init", 10, "Preparing OpenAI API request envelope");

  const messages = buildOpenAIMessages(input);
  const requestBody: Record<string, unknown> = {
    model,
    messages,
    temperature,
    max_tokens: maxTokens,
  };

  if (config.responseFormat === "json_object") {
    requestBody.response_format = { type: "json_object" };
  }

  try {
    context.progress("calling_api", 40, `Calling OpenAI model API (${model})`);

    const response = await fetchFn(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
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
        summary: `OpenAI API returned HTTP status ${response.status}`,
        output: null,
        artifactIds: [],
        error: {
          code: `OPENAI_HTTP_${response.status}`,
          message:
            errText || `HTTP request failed with status ${response.status}`,
          retryable: isRetryable,
        },
      };
    }

    context.progress("parsing_response", 80, "Parsing OpenAI model response");

    const data = (await response.json()) as {
      id?: string;
      choices?: Array<{
        message?: { content?: string };
        finish_reason?: string;
      }>;
      usage?: {
        prompt_tokens?: number;
        completion_tokens?: number;
        total_tokens?: number;
      };
    };

    const choice = data.choices?.[0];
    const rawContent = choice?.message?.content ?? "";
    const parsedEnvelope = parseCodexEnvelope(rawContent);

    const completedAt = new Date().toISOString();
    const inputTokens = data.usage?.prompt_tokens ?? null;
    const outputTokens = data.usage?.completion_tokens ?? null;

    const payload = parsedEnvelope?.payload ?? {
      status: "completed",
      summary: `OpenAI (${model}) completed task: ${input.objective}`,
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
      "OpenAI API task completed successfully",
    );

    return {
      status: "completed",
      summary:
        typeof payload.summary === "string"
          ? payload.summary
          : `OpenAI (${model}) successfully completed '${input.objective}'`,
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
          totalTokens: data.usage?.total_tokens ?? null,
          finishReason: choice?.finish_reason ?? null,
        },
        logs: [
          `[${startedAt}] OpenAI API request sent to ${endpoint} (${model})`,
          `[${completedAt}] OpenAI API response received (tokens: ${inputTokens ?? 0} in, ${outputTokens ?? 0} out)`,
        ],
      },
    };
  } catch (err: unknown) {
    const isAborted = context.signal.aborted;
    const errorMessage = err instanceof Error ? err.message : String(err);

    context.log("error", `OpenAI API execution error: ${errorMessage}`, {
      aborted: isAborted,
    });

    return {
      status: "failed",
      summary: isAborted
        ? "OpenAI API call was cancelled by host request"
        : `OpenAI API execution error: ${errorMessage}`,
      output: null,
      artifactIds: [],
      error: {
        code: isAborted ? "OPENAI_REQUEST_CANCELLED" : "OPENAI_EXECUTION_ERROR",
        message: errorMessage,
        retryable: isAborted,
      },
    };
  }
}

export const openaiApiWorkerDefinition: WorkerPluginDefinition =
  defineWorkerPlugin({
    manifest: openaiApiWorkerManifest,
    execute: executeOpenAIApiWorker,
  });
