import { describe, expect, it } from "vitest";

import {
  executeWithPolicy,
  ExecutionPolicyError,
  type WorkerExecutionRequest,
  type WorkerExecutor,
} from "../src/index.js";

function worker(id: string, output = id): WorkerExecutor {
  return {
    resource: {
      id,
      name: id,
      type: "model",
      capabilities: [],
      roles: [],
      permissions: [],
      independenceKey: id,
      connectionIds: [`connection-${id}`],
      availability: "available",
    },
    connection: {
      id: `connection-${id}`,
      name: id,
      transport: "provider_api",
      provider: id,
      adapterVersion: "test",
      authMode: "api_key",
      billingMode: "api_metered",
      cost: {
        currency: "USD",
        estimatedCostMicrosPerAttempt: 1,
        inputMicrosPerMillionTokens: null,
        outputMicrosPerMillionTokens: null,
      },
      executionEnvironment: "cloud",
      availability: "available",
    },
    async execute(request) {
      return {
        status: "succeeded",
        output: JSON.stringify({ worker: output, message: request.message }),
        rawOutput: null,
        usage: { inputTokens: null, outputTokens: null },
        evidenceArtifactIds: [],
      };
    },
  };
}

const request: WorkerExecutionRequest = {
  requestId: "policy-request",
  goalId: "goal-1",
  runId: "run-1",
  taskId: "task-1",
  attemptId: "attempt-1",
  workerId: "lead",
  connectionId: "lead-connection",
  repositoryId: "repo-1",
  message: { objective: "research" },
  context: [],
};

describe("execution policies", () => {
  it("executes single and parallel policies with correlated worker context", async () => {
    const one = await executeWithPolicy({
      policy: { mode: "single" },
      request,
      workers: [worker("one")],
    });
    const many = await executeWithPolicy({
      policy: { mode: "parallel", maxParallel: 2 },
      request,
      workers: [worker("one"), worker("two"), worker("three")],
    });

    expect(one.candidateResults).toHaveLength(1);
    expect(many.candidateResults).toHaveLength(3);
    expect(many.decisionResult).toBeNull();
  });

  it("synthesizes independent candidate results", async () => {
    const result = await executeWithPolicy({
      policy: { mode: "synthesize" },
      request,
      workers: [worker("research-a"), worker("research-b")],
      synthesizer: worker("synthesizer"),
    });

    expect(result.decisionResult?.status).toBe("succeeded");
    expect(result.decisionResult?.output).toContain("synthesize");
  });

  it("requires an independent selector for compare_and_select", async () => {
    await expect(
      executeWithPolicy({
        policy: { mode: "compare_and_select" },
        request,
        workers: [worker("one"), worker("two")],
        selector: worker("one"),
      }),
    ).rejects.toThrow(ExecutionPolicyError);
  });
});
