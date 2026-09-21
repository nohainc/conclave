import { describe, expect, it } from "vitest";

import {
  executeReadOnlyPanel,
  ReadOnlyRoleError,
  type ConnectionResource,
  type WorkerExecutionRequest,
  type WorkerExecutor,
  type WorkerResource,
} from "../src/index.js";

function makeWorker(
  id: string,
  role: "researcher" | "architect" | "planner" | "reviewer",
  permissions = ["repository_read"],
): WorkerExecutor {
  const capability = {
    researcher: "repository_research",
    architect: "architecture",
    planner: "planning",
    reviewer: "code_review",
  }[role];
  const resource: WorkerResource = {
    id,
    name: id,
    type: "model",
    capabilities: [capability],
    roles: [role],
    permissions,
    independenceKey: id,
    connectionIds: [`${id}-connection`],
    availability: "available",
  };
  const connection: ConnectionResource = {
    id: `${id}-connection`,
    name: id,
    transport: "provider_api",
    provider: id,
    adapterVersion: "1",
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
  };
  return {
    resource,
    connection,
    async execute(request) {
      return {
        status: "succeeded",
        output: `${request.workerId}:${request.requestId}`,
        rawOutput: null,
        usage: { inputTokens: null, outputTokens: null },
        evidenceArtifactIds: [],
      };
    },
  };
}

const request: WorkerExecutionRequest = {
  requestId: "readonly-panel",
  goalId: "goal-1",
  runId: "run-1",
  taskId: "task-1",
  attemptId: "attempt-1",
  workerId: "lead",
  connectionId: "lead-connection",
  repositoryId: "repo-1",
  message: { objective: "understand the repository" },
  context: [],
};

describe("read-only worker roles", () => {
  it("runs independent research, architecture, planning, and review workers", async () => {
    const executions = await executeReadOnlyPanel({
      request,
      roles: ["researcher", "architect", "planner", "reviewer"],
      workers: {
        researcher: makeWorker("researcher-1", "researcher"),
        architect: makeWorker("architect-1", "architect"),
        planner: makeWorker("planner-1", "planner"),
        reviewer: makeWorker("reviewer-1", "reviewer"),
      },
    });

    expect(executions.map((execution) => execution.role)).toEqual([
      "researcher",
      "architect",
      "planner",
      "reviewer",
    ]);
    expect(executions[0]?.result.output).toContain(":readonly:researcher");
  });

  it("rejects a worker that can write", async () => {
    await expect(
      executeReadOnlyPanel({
        request,
        roles: ["reviewer"],
        workers: {
          reviewer: makeWorker("writer", "reviewer", [
            "repository_read",
            "repository_write",
          ]),
        },
      }),
    ).rejects.toThrow(ReadOnlyRoleError);
  });

  it("rejects duplicate independence keys", async () => {
    const first = makeWorker("researcher-1", "researcher");
    const second = makeWorker("reviewer-1", "reviewer");
    (second.resource as { independenceKey: string }).independenceKey =
      first.resource.independenceKey;

    await expect(
      executeReadOnlyPanel({
        request,
        roles: ["researcher", "reviewer"],
        workers: { researcher: first, reviewer: second },
      }),
    ).rejects.toThrow("must be independent");
  });
});
