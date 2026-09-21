import { describe, expect, it } from "vitest";

import {
  ManualWorkerExecutor,
  RemoteWorkerExecutor,
  type ConnectionResource,
  type WorkerExecutionRequest,
  type WorkerResource,
} from "../src/index.js";

const resource: WorkerResource = {
  id: "manual-reviewer",
  name: "Manual Reviewer",
  type: "human",
  capabilities: ["code_review"],
  roles: ["reviewer"],
  permissions: ["repository_read"],
  independenceKey: "manual-reviewer",
  connectionIds: ["manual-connection"],
  availability: "available",
};
const connection: ConnectionResource = {
  id: "manual-connection",
  name: "Manual bridge",
  transport: "manual",
  provider: null,
  adapterVersion: "1",
  authMode: "manual",
  billingMode: "manual",
  cost: {
    currency: "USD",
    estimatedCostMicrosPerAttempt: null,
    inputMicrosPerMillionTokens: null,
    outputMicrosPerMillionTokens: null,
  },
  executionEnvironment: "human",
  availability: "available",
};
const request: WorkerExecutionRequest = {
  requestId: "manual-request",
  goalId: "goal-1",
  runId: "run-1",
  taskId: "task-1",
  attemptId: "attempt-1",
  workerId: resource.id,
  connectionId: connection.id,
  repositoryId: "repo-1",
  message: { objective: "review" },
  context: [],
};

function reviewOutput(): unknown {
  return {
    protocol: "conclave.protocol",
    version: "0.1",
    messageId: "review-result-1",
    goalId: "goal-1",
    runId: "run-1",
    workerId: resource.id,
    createdAt: "2026-01-01T00:00:00.000Z",
    messageType: "ReviewResult",
    payload: {
      taskId: "task-1",
      outcome: "pass",
      reviewedArtifactIds: [],
      resolvedFindingIds: [],
      findings: [],
      summary: "Reviewed",
    },
  };
}

describe("remote and manual workers", () => {
  it("validates a custom remote WorkerExecutionResult", async () => {
    const worker = new RemoteWorkerExecutor(resource, connection, {
      async execute() {
        return {
          executionId: "remote-1",
          result: {
            status: "succeeded",
            output: "ok",
            rawOutput: null,
            usage: { inputTokens: 1, outputTokens: 1 },
            evidenceArtifactIds: [],
          },
        };
      },
    });
    await expect(worker.execute(request)).resolves.toMatchObject({
      status: "succeeded",
      executionId: "remote-1",
    });
  });

  it("waits for and validates a manual protocol submission", async () => {
    const worker = new ManualWorkerExecutor(resource, connection);
    const waiting = await worker.execute(request);
    expect(waiting.status).toBe("waiting");
    const accepted = await worker.submit(waiting.executionId!, reviewOutput(), {
      expectedMessageType: "ReviewResult",
    });

    expect(accepted.accepted).toBe(true);
    expect(accepted.result.status).toBe("succeeded");
    expect(worker.pendingExecutionIds()).toHaveLength(0);
  });

  it("keeps a manual execution pending when context validation fails", async () => {
    const worker = new ManualWorkerExecutor(resource, connection);
    const waiting = await worker.execute(request);
    const wrong = {
      ...(reviewOutput() as Record<string, unknown>),
      runId: "other-run",
    };
    const rejected = await worker.submit(waiting.executionId!, wrong, {
      expectedMessageType: "ReviewResult",
    });

    expect(rejected.accepted).toBe(false);
    expect(worker.pendingExecutionIds()).toEqual([waiting.executionId]);
  });
});
