import { describe, expect, it } from "vitest";

import {
  executeWithFallback,
  executeWithPolicy,
  type ConnectionResource,
  type WorkerExecutionRequest,
  type WorkerExecutor,
  type WorkerResource,
} from "../src/index.js";

function webWorker(
  id: "chatgpt-web" | "claude-web" | "api-fallback" | "synthesizer",
  options: { unavailable?: boolean } = {},
): WorkerExecutor & { readonly attempts: WorkerExecutionRequest[] } {
  const attempts: WorkerExecutionRequest[] = [];
  const isWeb = id !== "api-fallback" && id !== "synthesizer";
  const resource: WorkerResource = {
    id,
    name: id,
    type: "model",
    capabilities: [id === "synthesizer" ? "synthesis" : "architecture"],
    roles: [id === "synthesizer" ? "synthesizer" : "architect"],
    permissions: ["repository_read"],
    independenceKey:
      id === "chatgpt-web"
        ? "openai-web"
        : id === "claude-web"
          ? "anthropic-web"
          : id,
    connectionIds: [`${id}-connection`],
    availability: "available",
  };
  const connection: ConnectionResource = {
    id: `${id}-connection`,
    name: id,
    transport: isWeb ? "web_app" : "provider_api",
    provider:
      id === "chatgpt-web"
        ? "openai"
        : id === "claude-web"
          ? "anthropic"
          : "openai",
    adapterVersion: "1",
    authMode: isWeb ? "subscription_session" : "api_key",
    billingMode: isWeb ? "subscription" : "api_metered",
    cost: {
      currency: "USD",
      estimatedCostMicrosPerAttempt: isWeb ? null : 100,
      inputMicrosPerMillionTokens: null,
      outputMicrosPerMillionTokens: null,
    },
    executionEnvironment: isWeb ? "cloud" : "cloud",
    availability: "available",
  };
  return {
    resource,
    connection,
    attempts,
    async execute(request) {
      attempts.push(request);
      if (options.unavailable) {
        return {
          status: "failed",
          output: null,
          rawOutput: null,
          usage: { inputTokens: null, outputTokens: null },
          evidenceArtifactIds: [],
          error: {
            code: "web_session_unavailable",
            message: `${id} session unavailable`,
            retryable: true,
          },
        };
      }
      if (id === "synthesizer") {
        const task = request.message as { payload?: { taskId?: string } };
        const taskId = task.payload?.taskId ?? "task-architecture:synthesize";
        return {
          status: "succeeded",
          output: JSON.stringify({
            protocol: "conclave.protocol",
            version: "0.1",
            messageId: "web-synthesis-1",
            goalId: request.goalId,
            runId: request.runId,
            workerId: id,
            createdAt: "2026-01-01T00:00:00.000Z",
            messageType: "DecisionResult",
            payload: {
              taskId,
              decisionType: "accept_plan",
              outcome: "accepted",
              rationale:
                "ChatGPT Web and Claude Web independently support the design",
              evidenceArtifactIds: [],
              transitions: [
                {
                  entityType: "task",
                  entityId: taskId,
                  from: "running",
                  to: "completed",
                },
              ],
            },
          }),
          rawOutput: null,
          usage: { inputTokens: null, outputTokens: null },
          evidenceArtifactIds: [],
        };
      }
      return {
        status: "succeeded",
        output: `${id}-architecture-candidate`,
        rawOutput: null,
        usage: { inputTokens: null, outputTokens: null },
        evidenceArtifactIds: [],
      };
    },
  };
}

const request: WorkerExecutionRequest = {
  requestId: "web-ensemble",
  goalId: "goal-1",
  runId: "run-1",
  taskId: "task-architecture",
  attemptId: "attempt-architecture",
  workerId: "lead",
  connectionId: "lead-connection",
  repositoryId: "repo-1",
  message: { objective: "Design the architecture" },
  context: [],
};

describe("web-worker ensemble acceptance", () => {
  it("accepts independent ChatGPT Web and Claude Web architecture candidates", async () => {
    const chatgpt = webWorker("chatgpt-web");
    const claude = webWorker("claude-web");
    const synthesizer = webWorker("synthesizer");
    const result = await executeWithPolicy({
      policy: { mode: "synthesize", maxParallel: 2 },
      request,
      workers: [chatgpt, claude],
      synthesizer,
    });

    expect(result.decision?.payload.outcome).toBe("accepted");
    expect(chatgpt.connection.billingMode).toBe("subscription");
    expect(claude.connection.billingMode).toBe("subscription");
    expect(chatgpt.connection.transport).toBe("web_app");
    expect(claude.connection.transport).toBe("web_app");
    expect(chatgpt.resource.independenceKey).not.toBe(
      claude.resource.independenceKey,
    );
    expect(chatgpt.attempts[0]?.attemptId).not.toBe(
      claude.attempts[0]?.attemptId,
    );
    expect(synthesizer.attempts[0]?.attemptId).toContain(
      ":decision:synthesize",
    );
  });

  it("falls back from an unavailable web worker to an API worker", async () => {
    const claude = webWorker("claude-web", { unavailable: true });
    const api = webWorker("api-fallback");
    const result = await executeWithFallback(request, [claude, api]);

    expect(result.selectedWorkerId).toBe("api-fallback");
    expect(result.attempts).toHaveLength(2);
    expect(result.attempts[0]?.result.error?.retryable).toBe(true);
    expect(api.connection.billingMode).toBe("api_metered");
  });
});
