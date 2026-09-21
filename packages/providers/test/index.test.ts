import { describe, expect, it } from "vitest";
import {
  AnthropicMessagesWorker,
  OpenAIResponsesWorker,
  type HttpTransport,
} from "../src/index.js";
import type { WorkerResource } from "@conclave/core";

const resource = (provider: string): WorkerResource => ({
  id: `${provider}-worker`,
  name: `${provider}-model`,
  type: "model",
  provider,
  adapterVersion: "1",
  capabilities: ["planning"],
  roles: ["lead"],
  permissions: [],
  availability: "available",
  cost: {
    currency: "USD",
    estimatedCostMicrosPerAttempt: 1,
    inputMicrosPerMillionTokens: 1,
    outputMicrosPerMillionTokens: 1,
  },
  executionEnvironment: "cloud",
});

const message = {
  protocol: "conclave.protocol" as const,
  version: "0.1" as const,
  messageId: "message-1",
  goalId: "goal-1",
  runId: "run-1",
  workerId: "worker-1",
  createdAt: "2026-09-21T10:00:00.000Z",
  messageType: "PlanRequest" as const,
  payload: {
    taskId: "task-plan",
    objective: "Plan",
    constraints: [],
    repository: { repositoryId: "repo-1", revision: "main" },
    completionCriteria: ["Done"],
  },
};

function transport(body: string, status = 200): HttpTransport {
  return { fetch: async () => new Response(body, { status }) };
}

describe("real model provider adapters", () => {
  it("adapts an OpenAI Responses JSON response", async () => {
    let requestBody = "";
    const worker = new OpenAIResponsesWorker({
      apiKey: "openai-secret",
      model: "openai-model",
      resource: resource("openai"),
      endpoint: "https://provider.test/openai",
      transport: {
        fetch: async (_input, init) => {
          requestBody = String(init?.body);
          return new Response(
            JSON.stringify({
              id: "resp-1",
              output_text: JSON.stringify(message),
              usage: { input_tokens: 4, output_tokens: 5 },
            }),
            { status: 200 },
          );
        },
      },
    });

    const result = await worker.complete({
      message,
      context: [
        {
          artifactId: "artifact-1",
          mediaType: "text/plain",
          content: "actual repository evidence",
          truncated: false,
          originalLength: 26,
          estimatedTokens: 7,
        },
      ],
    });
    expect(result.providerRequestId).toBe("resp-1");
    expect(JSON.parse(result.text)).toEqual(message);
    expect(result.usage).toEqual({ inputTokens: 4, outputTokens: 5 });
    expect(requestBody).toContain("actual repository evidence");
  });

  it("adapts an Anthropic Messages text response", async () => {
    const worker = new AnthropicMessagesWorker({
      apiKey: "anthropic-secret",
      model: "anthropic-model",
      resource: resource("anthropic"),
      endpoint: "https://provider.test/anthropic",
      transport: transport(
        JSON.stringify({
          id: "msg-1",
          content: [{ type: "text", text: JSON.stringify(message) }],
          usage: { input_tokens: 6, output_tokens: 7 },
        }),
      ),
    });

    const result = await worker.complete({ message });
    expect(result.providerRequestId).toBe("msg-1");
    expect(JSON.parse(result.text)).toEqual(message);
    expect(result.usage).toEqual({ inputTokens: 6, outputTokens: 7 });
  });
});
