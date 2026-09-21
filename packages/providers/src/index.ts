import type {
  ConnectionResource,
  WorkerExecutionRequest,
  WorkerExecutionResult,
  WorkerExecutor,
  WorkerResource,
} from "@conclave/core";
import type { ProtocolMessage } from "@conclave/protocol";

export interface ModelContextItem {
  readonly artifactId: string;
  readonly mediaType: string;
  readonly content: string;
  readonly truncated: boolean;
  readonly originalLength: number;
  readonly estimatedTokens: number;
}

export interface ModelRequest {
  readonly message: ProtocolMessage;
  readonly context?: readonly ModelContextItem[];
  readonly systemPrompt?: string;
}

export interface ModelUsage {
  readonly inputTokens: number | null;
  readonly outputTokens: number | null;
}

export interface ModelResponse {
  readonly providerRequestId: string;
  readonly text: string;
  readonly rawResponse: string;
  readonly usage: ModelUsage;
}

export interface ModelWorker extends WorkerExecutor {
  complete(request: ModelRequest): Promise<ModelResponse>;
}

export interface HttpTransport {
  fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response>;
}

interface OpenAIResponseBody {
  readonly id?: unknown;
  readonly output_text?: unknown;
  readonly output?: unknown;
  readonly usage?: {
    readonly input_tokens?: unknown;
    readonly output_tokens?: unknown;
  };
}

interface AnthropicResponseBody {
  readonly id?: unknown;
  readonly content?: unknown;
  readonly usage?: {
    readonly input_tokens?: unknown;
    readonly output_tokens?: unknown;
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function numberOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isInteger(value) ? value : null;
}

function stringOrThrow(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`Provider response is missing ${field}`);
  }
  return value;
}

function responseTextFromOpenAI(body: OpenAIResponseBody): string {
  if (typeof body.output_text === "string") {
    return body.output_text;
  }
  if (Array.isArray(body.output)) {
    for (const item of body.output) {
      if (!isRecord(item) || !Array.isArray(item.content)) continue;
      for (const content of item.content) {
        if (isRecord(content) && typeof content.text === "string")
          return content.text;
      }
    }
  }
  throw new Error("OpenAI response contains no text output");
}

function responseTextFromAnthropic(body: AnthropicResponseBody): string {
  if (Array.isArray(body.content)) {
    for (const content of body.content) {
      if (
        isRecord(content) &&
        content.type === "text" &&
        typeof content.text === "string"
      ) {
        return content.text;
      }
    }
  }
  throw new Error("Anthropic response contains no text output");
}

function jsonResponseFormat(): Record<string, unknown> {
  return { type: "json_object" };
}

function failedExecution(error: unknown): WorkerExecutionResult {
  return {
    status: "failed",
    output: null,
    rawOutput: null,
    usage: { inputTokens: null, outputTokens: null },
    evidenceArtifactIds: [],
    error: {
      code: "provider_execution_failed",
      message:
        error instanceof Error ? error.message : "unknown provider error",
      retryable: true,
    },
  };
}

export interface OpenAIResponsesWorkerOptions {
  readonly apiKey: string;
  readonly model: string;
  readonly resource: WorkerResource;
  readonly connection: ConnectionResource;
  readonly transport?: HttpTransport;
  readonly endpoint?: string;
}

export class OpenAIResponsesWorker implements ModelWorker {
  readonly resource: WorkerResource;
  readonly connection: ConnectionResource;
  private readonly apiKey: string;
  private readonly model: string;
  private readonly transport: HttpTransport;
  private readonly endpoint: string;

  constructor(options: OpenAIResponsesWorkerOptions) {
    this.resource = options.resource;
    this.connection = options.connection;
    this.apiKey = options.apiKey;
    this.model = options.model;
    this.transport = options.transport ?? { fetch };
    this.endpoint = options.endpoint ?? "https://api.openai.com/v1/responses";
  }

  async execute(
    request: WorkerExecutionRequest,
  ): Promise<WorkerExecutionResult> {
    try {
      const response = await this.complete({
        message: request.message as ProtocolMessage,
        context: request.context,
        ...(request.systemPrompt ? { systemPrompt: request.systemPrompt } : {}),
      });
      return {
        status: "succeeded",
        output: response.text,
        rawOutput: response.rawResponse,
        providerRequestId: response.providerRequestId,
        usage: response.usage,
        evidenceArtifactIds: [],
      };
    } catch (error) {
      return failedExecution(error);
    }
  }

  async complete(request: ModelRequest): Promise<ModelResponse> {
    const response = await this.transport.fetch(this.endpoint, {
      method: "POST",
      headers: {
        authorization: `Bearer ${this.apiKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: this.model,
        store: false,
        input: [
          ...(request.systemPrompt
            ? [{ role: "developer", content: request.systemPrompt }]
            : []),
          {
            role: "user",
            content: JSON.stringify({
              message: request.message,
              context: request.context ?? [],
            }),
          },
        ],
        text: { format: jsonResponseFormat() },
      }),
    });
    const body: unknown = await response.json();
    const rawResponse = JSON.stringify(body);
    if (!response.ok)
      throw new Error(`OpenAI request failed with status ${response.status}`);
    if (!isRecord(body)) throw new Error("OpenAI response is not an object");
    const typedBody = body as OpenAIResponseBody;
    return {
      providerRequestId: stringOrThrow(typedBody.id, "id"),
      text: responseTextFromOpenAI(typedBody),
      rawResponse,
      usage: {
        inputTokens: numberOrNull(typedBody.usage?.input_tokens),
        outputTokens: numberOrNull(typedBody.usage?.output_tokens),
      },
    };
  }
}

export interface AnthropicMessagesWorkerOptions {
  readonly apiKey: string;
  readonly model: string;
  readonly resource: WorkerResource;
  readonly connection: ConnectionResource;
  readonly transport?: HttpTransport;
  readonly endpoint?: string;
  readonly apiVersion?: string;
}

export class AnthropicMessagesWorker implements ModelWorker {
  readonly resource: WorkerResource;
  readonly connection: ConnectionResource;
  private readonly apiKey: string;
  private readonly model: string;
  private readonly transport: HttpTransport;
  private readonly endpoint: string;
  private readonly apiVersion: string;

  constructor(options: AnthropicMessagesWorkerOptions) {
    this.resource = options.resource;
    this.connection = options.connection;
    this.apiKey = options.apiKey;
    this.model = options.model;
    this.transport = options.transport ?? { fetch };
    this.endpoint = options.endpoint ?? "https://api.anthropic.com/v1/messages";
    this.apiVersion = options.apiVersion ?? "2023-06-01";
  }

  async execute(
    request: WorkerExecutionRequest,
  ): Promise<WorkerExecutionResult> {
    try {
      const response = await this.complete({
        message: request.message as ProtocolMessage,
        context: request.context,
        ...(request.systemPrompt ? { systemPrompt: request.systemPrompt } : {}),
      });
      return {
        status: "succeeded",
        output: response.text,
        rawOutput: response.rawResponse,
        providerRequestId: response.providerRequestId,
        usage: response.usage,
        evidenceArtifactIds: [],
      };
    } catch (error) {
      return failedExecution(error);
    }
  }

  async complete(request: ModelRequest): Promise<ModelResponse> {
    const response = await this.transport.fetch(this.endpoint, {
      method: "POST",
      headers: {
        "x-api-key": this.apiKey,
        "anthropic-version": this.apiVersion,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: this.model,
        max_tokens: 4096,
        ...(request.systemPrompt ? { system: request.systemPrompt } : {}),
        messages: [
          {
            role: "user",
            content: JSON.stringify({
              message: request.message,
              context: request.context ?? [],
            }),
          },
        ],
      }),
    });
    const body: unknown = await response.json();
    const rawResponse = JSON.stringify(body);
    if (!response.ok)
      throw new Error(
        `Anthropic request failed with status ${response.status}`,
      );
    if (!isRecord(body)) throw new Error("Anthropic response is not an object");
    const typedBody = body as AnthropicResponseBody;
    return {
      providerRequestId: stringOrThrow(typedBody.id, "id"),
      text: responseTextFromAnthropic(typedBody),
      rawResponse,
      usage: {
        inputTokens: numberOrNull(typedBody.usage?.input_tokens),
        outputTokens: numberOrNull(typedBody.usage?.output_tokens),
      },
    };
  }
}
