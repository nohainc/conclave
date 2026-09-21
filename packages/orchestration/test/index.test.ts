import { describe, expect, it } from "vitest";
import type { GoalRecord, RunRecord } from "@conclave/persistence";
import type {
  ModelRequest,
  ModelResponse,
  ModelWorker,
} from "@conclave/providers";
import { InMemoryMvpPersistence, executeTwoModelGoal } from "../src/index.js";
import type { ConnectionResource, WorkerResource } from "@conclave/core";

const connection = (id: string): ConnectionResource => ({
  id: `${id}-connection`,
  name: `${id}-connection`,
  transport: "provider_api",
  provider: id,
  adapterVersion: "1",
  authMode: "api_key",
  billingMode: "api_metered",
  cost: {
    currency: "USD",
    estimatedCostMicrosPerAttempt: 1,
    inputMicrosPerMillionTokens: 1,
    outputMicrosPerMillionTokens: 1,
  },
  executionEnvironment: "cloud",
  availability: "available",
});

const makeResource = (id: string, role: string): WorkerResource => ({
  id,
  name: `${id}-model`,
  type: "model",
  capabilities: [role === "lead" ? "planning" : "implementation", "evaluation"],
  roles: [role],
  permissions: ["repository_read"],
  independenceKey: id,
  connectionIds: [`${id}-connection`],
  availability: "available",
});

class FakeWorker implements ModelWorker {
  readonly resource: WorkerResource;
  private readonly outputs: readonly string[];
  private cursor = 0;

  constructor(resource: WorkerResource, outputs: readonly string[]) {
    this.resource = resource;
    this.outputs = outputs;
  }

  get connection(): ConnectionResource {
    return connection(this.resource.id);
  }

  complete(request: ModelRequest): Promise<ModelResponse> {
    const output = this.outputs[this.cursor++];
    if (output === undefined) throw new Error("No fake model output remaining");
    const parsed = JSON.parse(output) as {
      payload?: Record<string, unknown>;
    };
    const requestPayload = request.message.payload;
    if (
      typeof requestPayload === "object" &&
      requestPayload !== null &&
      "taskId" in requestPayload &&
      typeof requestPayload.taskId === "string" &&
      parsed.payload
    ) {
      parsed.payload.taskId = requestPayload.taskId;
    }
    const text = JSON.stringify(parsed);
    return Promise.resolve({
      providerRequestId: `${this.resource.id}-request-${this.cursor}`,
      text,
      rawResponse: JSON.stringify({
        id: `raw-${this.cursor}`,
        output_text: text,
      }),
      usage: { inputTokens: 1, outputTokens: 1 },
    });
  }
}

const goal: GoalRecord = {
  id: "goal-1",
  projectId: "project-1",
  originalMessage: "Add a greeting",
  objective: "Add a greeting",
  constraints: [],
  completionCriteria: [
    {
      id: "criterion-1",
      description: "The greeting is implemented",
      verificationRequirement: "policy_check",
      status: "pending",
      evidenceArtifactIds: [],
      verifiedByWorkerId: null,
      verificationId: null,
      createdAt: "2026-09-21T10:00:00.000Z",
      updatedAt: "2026-09-21T10:00:00.000Z",
    },
  ],
  verificationPolicy: {},
  status: "running",
  createdAt: "2026-09-21T10:00:00.000Z",
  updatedAt: "2026-09-21T10:00:00.000Z",
};

const run: RunRecord = {
  id: "run-1",
  goalId: goal.id,
  parentRunId: null,
  policySnapshot: {},
  currentPhaseId: null,
  status: "active",
  startedAt: "2026-09-21T10:00:00.000Z",
  finishedAt: null,
  createdAt: "2026-09-21T10:00:00.000Z",
  updatedAt: "2026-09-21T10:00:00.000Z",
};

describe("two-model MVP orchestration", () => {
  it("runs Lead -> Specialist -> Lead and persists each exchange", async () => {
    const lead = new FakeWorker(makeResource("lead-worker", "lead"), [
      JSON.stringify({
        protocol: "conclave.protocol",
        version: "0.1",
        messageId: "plan-result",
        goalId: goal.id,
        runId: run.id,
        workerId: "lead-worker",
        createdAt: "2026-09-21T10:01:00.000Z",
        messageType: "PlanResult",
        payload: {
          phases: [
            {
              phaseId: "phase-1",
              name: "Implementation",
              purpose: "Implement",
              tasks: [
                {
                  taskId: "task-specialist",
                  objective: "Add greeting",
                  role: "specialist",
                  capabilities: ["implementation"],
                  dependsOnTaskIds: [],
                  requiresIndependentVerification: false,
                },
              ],
            },
          ],
          assumptions: [],
          risks: [],
        },
      }),
      JSON.stringify({
        protocol: "conclave.protocol",
        version: "0.1",
        messageId: "completion-result",
        goalId: goal.id,
        runId: run.id,
        workerId: "lead-worker",
        createdAt: "2026-09-21T10:03:00.000Z",
        messageType: "CompletionResult",
        payload: {
          outcome: "completed",
          criteria: [
            {
              criterionId: "criterion-1",
              status: "satisfied",
              evidenceArtifactIds: [],
            },
          ],
          finalReportArtifactId: "report-1",
          unresolvedFindingIds: [],
          remainingRisks: [],
        },
      }),
    ]);
    const specialist = new FakeWorker(
      makeResource("specialist-worker", "specialist"),
      [
        JSON.stringify({
          protocol: "conclave.protocol",
          version: "0.1",
          messageId: "task-result",
          goalId: goal.id,
          runId: run.id,
          workerId: "specialist-worker",
          createdAt: "2026-09-21T10:02:00.000Z",
          messageType: "TaskResult",
          payload: {
            taskId: "task-specialist",
            status: "succeeded",
            summary: "Greeting added",
            artifactIds: [],
            findingIds: [],
          },
        }),
      ],
    );
    const persistence = new InMemoryMvpPersistence();

    const result = await executeTwoModelGoal({
      goal,
      run,
      repositoryId: "repo-1",
      revision: "main",
      lead,
      specialist,
      persistence,
      idFactory: (() => {
        let value = 0;
        return () => `generated-${++value}`;
      })(),
      now: () => "2026-09-21T10:00:00.000Z",
    });

    expect(result.completion.payload.outcome).toBe("completed");
    expect(persistence.modelCalls).toHaveLength(3);
    expect(
      persistence.artifacts.some((artifact) => artifact.id === "report-1"),
    ).toBe(true);
    expect(
      persistence.events.filter(
        (event) => event.eventType === "ModelRequestPersisted",
      ),
    ).toHaveLength(3);
    expect(
      persistence.events.filter(
        (event) => event.eventType === "ModelResultAccepted",
      ),
    ).toHaveLength(3);
    expect(persistence.events.at(-1)?.eventType).toBe("RunCompleted");
  });
});
