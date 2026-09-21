import { describe, expect, it } from "vitest";

import {
  executeParallelImplementations,
  executeReadOnlyPanel,
  executeWithFallback,
  executeWithPolicy,
  resolveQuality,
  type ConnectionResource,
  type WorkerExecutionRequest,
  type WorkerExecutor,
  type WorkerResource,
} from "../src/index.js";

type Role = "researcher" | "architect" | "planner" | "reviewer" | "implementer";

function makeWorker(
  id: string,
  role: Role,
  options: {
    transport?: ConnectionResource["transport"];
    independenceKey?: string;
    outcome?: "succeeded" | "failed";
    retryable?: boolean;
    output?: string;
  } = {},
): WorkerExecutor {
  const capability =
    role === "researcher"
      ? "repository_research"
      : role === "architect"
        ? "architecture"
        : role === "planner"
          ? "planning"
          : role === "reviewer"
            ? "code_review"
            : "implementation";
  const resource: WorkerResource = {
    id,
    name: id,
    type: role === "implementer" ? "agent" : "model",
    capabilities: [capability],
    roles: [role],
    permissions:
      role === "implementer"
        ? ["repository_read", "repository_write"]
        : ["repository_read"],
    independenceKey: options.independenceKey ?? id,
    connectionIds: [`${id}-connection`],
    availability: "available",
  };
  const connection: ConnectionResource = {
    id: `${id}-connection`,
    name: id,
    transport: options.transport ?? "provider_api",
    provider: options.transport === "local_agent" ? null : id,
    adapterVersion: "1",
    authMode:
      options.transport === "local_agent" ? "subscription_session" : "api_key",
    billingMode:
      options.transport === "local_agent" ? "subscription" : "api_metered",
    cost: {
      currency: "USD",
      estimatedCostMicrosPerAttempt:
        options.transport === "local_agent" ? null : 100,
      inputMicrosPerMillionTokens: null,
      outputMicrosPerMillionTokens: null,
    },
    executionEnvironment:
      options.transport === "local_agent" ? "local" : "cloud",
    availability: "available",
  };
  return {
    resource,
    connection,
    async execute(request) {
      if (options.outcome === "failed") {
        return {
          status: "failed",
          output: null,
          rawOutput: null,
          usage: { inputTokens: null, outputTokens: null },
          evidenceArtifactIds: [],
          error: {
            code: "worker_unavailable",
            message: `${id} unavailable`,
            retryable: options.retryable ?? true,
          },
        };
      }
      if (role === "implementer") {
        return {
          status: "succeeded",
          output: options.output ?? request.repositoryId,
          rawOutput: null,
          usage: { inputTokens: 10, outputTokens: 10 },
          evidenceArtifactIds: [],
        };
      }
      if (id === "synthesizer") {
        const task = request.message as { payload?: { taskId?: string } };
        return {
          status: "succeeded",
          output: JSON.stringify({
            protocol: "conclave.protocol",
            version: "0.1",
            messageId: "decision-1",
            goalId: request.goalId,
            runId: request.runId,
            workerId: id,
            createdAt: "2026-01-01T00:00:00.000Z",
            messageType: "DecisionResult",
            payload: {
              taskId: task.payload?.taskId ?? "task-1:synthesize",
              decisionType: "accept_plan",
              outcome: "accepted",
              rationale: "Independent candidates agree",
              evidenceArtifactIds: [],
              transitions: [
                {
                  entityType: "task",
                  entityId: task.payload?.taskId ?? "task-1:synthesize",
                  from: "running",
                  to: "completed",
                },
              ],
            },
          }),
          rawOutput: null,
          usage: { inputTokens: 10, outputTokens: 10 },
          evidenceArtifactIds: [],
        };
      }
      return {
        status: "succeeded",
        output: `${id}:${request.requestId}`,
        rawOutput: null,
        usage: { inputTokens: 10, outputTokens: 10 },
        evidenceArtifactIds: [],
      };
    },
  };
}

const request: WorkerExecutionRequest = {
  requestId: "ensemble-acceptance",
  goalId: "goal-1",
  runId: "run-1",
  taskId: "task-1",
  attemptId: "attempt-1",
  workerId: "lead",
  connectionId: "lead-connection",
  repositoryId: "repo-1",
  message: { objective: "fix and verify" },
  context: [],
};

describe("ensemble acceptance scenarios", () => {
  it("completes a one-worker policy", async () => {
    const result = await executeWithPolicy({
      policy: { mode: "single" },
      request,
      workers: [makeWorker("lead", "planner")],
    });
    expect(result.candidateResults[0]?.status).toBe("succeeded");
  });

  it("runs multi-research read-only workers concurrently", async () => {
    const result = await executeReadOnlyPanel({
      request,
      roles: ["researcher", "architect", "reviewer"],
      workers: {
        researcher: makeWorker("research", "researcher"),
        architect: makeWorker("architect", "architect"),
        reviewer: makeWorker("reviewer", "reviewer"),
      },
    });
    expect(result).toHaveLength(3);
  });

  it("completes the high-assurance candidate and synthesis path", async () => {
    const quality = resolveQuality("high_assurance");
    const result = await executeWithPolicy({
      policy: quality.config,
      request,
      workers: [
        makeWorker("candidate-a", "planner"),
        makeWorker("candidate-b", "planner"),
      ],
      synthesizer: makeWorker("synthesizer", "planner"),
    });
    expect(result.decision?.payload.outcome).toBe("accepted");
  });

  it("runs competitive implementations in isolated workspaces", async () => {
    const result = await executeParallelImplementations({
      request,
      executions: [
        {
          worker: makeWorker("codex", "implementer", {
            transport: "local_agent",
          }),
          workspaceRepositoryId: "repo-1::codex",
        },
        {
          worker: makeWorker("api", "implementer"),
          workspaceRepositoryId: "repo-1::api",
        },
      ],
    });
    expect(result.map((entry) => entry.workspaceRepositoryId)).toEqual([
      "repo-1::codex",
      "repo-1::api",
    ]);
  });

  it("falls back from a subscription worker to an API worker", async () => {
    const result = await executeWithFallback(request, [
      makeWorker("local-codex", "implementer", {
        transport: "local_agent",
        outcome: "failed",
        retryable: true,
      }),
      makeWorker("api-implementer", "implementer", { output: "api-patch" }),
    ]);
    expect(result.selectedWorkerId).toBe("api-implementer");
    expect(result.attempts).toHaveLength(2);
    expect(result.result.output).toBe("api-patch");
  });
});
