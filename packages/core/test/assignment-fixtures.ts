import type {
  Worker,
  WorkerAssignmentRequest,
  WorkerAssignmentResponse,
  WorkerAssignmentRunner,
} from "../src/index.js";

export const request: WorkerAssignmentRequest = {
  requestId: "assignment-request",
  goalId: "goal-1",
  runId: "run-1",
  taskId: "task-1",
  attemptId: "attempt-1",
  workerId: "worker-1",
  repositoryId: "repo-1",
  message: { objective: "test" },
  context: [],
};

export function worker(
  id: string,
  options: {
    roles?: readonly string[];
    capabilities?: readonly string[];
    independenceKey?: string;
    cost?: number | null;
    outcome?: "completed" | "failed";
  } = {},
): WorkerAssignmentRunner {
  const entity: Worker = {
    id,
    workspaceId: "workspace-1",
    agentId: `agent-${id}`,
    pluginId: `plugin-${id}`,
    pluginVersionPolicy: "latest",
    name: id,
    roles: options.roles ?? [
      "planner",
      "researcher",
      "reviewer",
      "implementer",
    ],
    capabilities: options.capabilities ?? [
      "planning",
      "repository_research",
      "architecture",
      "code_review",
      "implementation",
      "synthesis",
    ],
    config: {},
    secretRefs: [],
    enabled: true,
    availability: "available",
    billingMode: "subscription",
    costMetadata: {
      currency: "USD",
      estimatedCostMicrosPerAttempt: options.cost ?? 100,
    },
    independenceKey: options.independenceKey ?? id,
    concurrencyLimit: 1,
    sessionPolicy: "stateless",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
  };
  return {
    worker: entity,
    async execute(input): Promise<WorkerAssignmentResponse> {
      if (options.outcome === "failed") {
        return {
          assignmentId: input.attemptId,
          workspaceId: entity.workspaceId,
          runId: input.runId,
          taskId: input.taskId,
          attemptId: input.attemptId,
          agentId: entity.agentId,
          workerId: entity.id,
          status: "failed",
          output: null,
          error: {
            code: "unavailable",
            message: "unavailable",
            retryable: true,
          },
          completedAt: "2026-01-01T00:00:00.000Z",
        };
      }
      return {
        assignmentId: input.attemptId,
        workspaceId: entity.workspaceId,
        runId: input.runId,
        taskId: input.taskId,
        attemptId: input.attemptId,
        agentId: entity.agentId,
        workerId: entity.id,
        status: "completed",
        output: {
          protocol: "conclave.protocol",
          version: "0.1",
          messageId: `${entity.id}-result`,
          goalId: input.goalId,
          runId: input.runId,
          workerId: entity.id,
          createdAt: "2026-01-01T00:00:00.000Z",
          messageType: "DecisionResult",
          payload: {
            taskId: input.taskId,
            decisionType: "accept_plan",
            outcome: "accepted",
            rationale: "accepted",
            evidenceArtifactIds: [],
            transitions: [
              {
                entityType: "task",
                entityId: input.taskId,
                from: "running",
                to: "completed",
              },
            ],
          },
        },
        completedAt: "2026-01-01T00:00:00.000Z",
        usage: { inputTokens: 1, outputTokens: 1 },
      };
    },
  };
}
