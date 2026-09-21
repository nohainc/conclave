import { describe, expect, it } from "vitest";

import {
  executeParallelImplementations,
  ParallelImplementationError,
  type ConnectionResource,
  type WorkerExecutionRequest,
  type WorkerExecutor,
  type WorkerResource,
} from "../src/index.js";

function worker(id: string, independenceKey = id): WorkerExecutor {
  const resource: WorkerResource = {
    id,
    name: id,
    type: "agent",
    capabilities: ["implementation"],
    roles: ["implementer"],
    permissions: ["repository_read", "repository_write"],
    independenceKey,
    connectionIds: [`${id}-connection`],
    availability: "available",
  };
  const connection: ConnectionResource = {
    id: `${id}-connection`,
    name: id,
    transport: "local_agent",
    provider: null,
    adapterVersion: "1",
    authMode: "subscription_session",
    billingMode: "subscription",
    cost: {
      currency: "USD",
      estimatedCostMicrosPerAttempt: null,
      inputMicrosPerMillionTokens: null,
      outputMicrosPerMillionTokens: null,
    },
    executionEnvironment: "local",
    availability: "available",
  };
  return {
    resource,
    connection,
    async execute(request) {
      return {
        status: "succeeded",
        output: request.repositoryId,
        rawOutput: null,
        usage: { inputTokens: null, outputTokens: null },
        evidenceArtifactIds: [],
      };
    },
  };
}

const request: WorkerExecutionRequest = {
  requestId: "implementation",
  goalId: "goal-1",
  runId: "run-1",
  taskId: "task-1",
  attemptId: "attempt-1",
  workerId: "lead",
  connectionId: "lead-connection",
  repositoryId: "repo-1",
  message: { objective: "implement the change" },
  context: [],
};

describe("parallel implementations", () => {
  it("routes each worker to its own workspace repository", async () => {
    const results = await executeParallelImplementations({
      request,
      executions: [
        {
          worker: worker("one"),
          workspaceRepositoryId: "repo-1/workspace-one",
        },
        {
          worker: worker("two"),
          workspaceRepositoryId: "repo-1/workspace-two",
        },
      ],
    });

    expect(results.map((result) => result.result.output)).toEqual([
      "repo-1/workspace-one",
      "repo-1/workspace-two",
    ]);
  });

  it("rejects shared workspaces and shared independence keys", async () => {
    await expect(
      executeParallelImplementations({
        request,
        executions: [
          { worker: worker("one", "same"), workspaceRepositoryId: "shared" },
          { worker: worker("two", "same"), workspaceRepositoryId: "shared" },
        ],
      }),
    ).rejects.toThrow(ParallelImplementationError);
  });
});
