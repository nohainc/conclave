import { describe, expect, it } from "vitest";
import { ConclaveRunWorkflow } from "../src/workflow.js";

function workflow(
  terminalEvents: readonly Record<string, unknown>[],
  executionId = "forge-execution-1",
) {
  const service = {
    fetch: async () => Response.json({ executionId }, { status: 202 }),
  };
  const env = {
    CONCLAVE_FORGE_EXECUTION: service,
  } as unknown as Env;
  const instance = new ConclaveRunWorkflow({} as never, env);
  const queue = [...terminalEvents];
  const step = {
    do: async <T>(
      _name: string,
      _config: unknown,
      callback: () => Promise<T>,
    ) => callback(),
    waitForEvent: async <T>() => ({ payload: queue.shift() }) as { payload: T },
  } as unknown as import("cloudflare:workers").WorkflowStep;
  return { instance, step };
}

const params = {
  runId: "run-1",
  goalId: "goal-1",
  idempotencyKey: "key-1",
  requireCiEvidence: false,
};

describe("durable Forge lifecycle", () => {
  it("does not complete until Forge reports completion", async () => {
    const { instance, step } = workflow([
      {
        eventId: "forge-event-1",
        runId: "run-1",
        executionId: "forge-execution-1",
        status: "completed",
        resultArtifactId: "artifact-1",
      },
    ]);
    const result = await instance.run({ payload: params } as never, step);
    expect(result.stage).toBe("completed");
    expect(result.executionStatus).toBe("completed");
    expect(result.resultArtifactId).toBe("artifact-1");
  });

  it("surfaces Forge failure without entering verification or completion", async () => {
    const { instance, step } = workflow([
      {
        eventId: "forge-event-2",
        runId: "run-1",
        executionId: "forge-execution-1",
        status: "failed",
        error: "implementation failed",
      },
    ]);
    const result = await instance.run({ payload: params } as never, step);
    expect(result.stage).toBe("failed");
    expect(result.status).toBe("failed");
    expect(result.executionStatus).toBe("failed");
    expect(result.failureReason).toBe("implementation failed");
  });

  it("rejects terminal results for a different run or execution", async () => {
    const { instance, step } = workflow([
      {
        eventId: "forge-event-3",
        runId: "other-run",
        executionId: "forge-execution-1",
        status: "completed",
      },
    ]);
    await expect(
      instance.run({ payload: params } as never, step),
    ).rejects.toThrow("does not match this run");
  });

  it("accepts only CI evidence correlated to the run revision", async () => {
    const correlatedParams = {
      ...params,
      repositoryId: "repo-1",
      expectedCommitSha: "abc1234",
      allowedWorkflows: ["CI"],
      expectedChecks: ["typecheck"],
      requireCiEvidence: true,
    };
    const { instance, step } = workflow([
      {
        eventId: "forge-event-4",
        runId: "run-1",
        executionId: "forge-execution-1",
        status: "completed",
      },
      {
        evidenceId: "evidence-1",
        runId: "run-1",
        repositoryId: "repo-1",
        source: "github_actions",
        externalRunId: "github-1",
        commitSha: "abc1234",
        workflow: "CI",
        conclusion: "success",
        checks: [{ name: "typecheck", status: "passed", artifactIds: [] }],
        smokeTests: [],
        healthChecks: [],
        observedAt: "2026-09-21T10:00:00.000Z",
      },
    ]);
    const result = await instance.run(
      { payload: correlatedParams } as never,
      step,
    );
    expect(result.stage).toBe("completed");
    expect(result.machineEvidence?.commitSha).toBe("abc1234");
  });

  it("rejects CI evidence for an old commit", async () => {
    const correlatedParams = {
      ...params,
      repositoryId: "repo-1",
      expectedCommitSha: "abc1234",
      requireCiEvidence: true,
    };
    const { instance, step } = workflow([
      {
        eventId: "forge-event-5",
        runId: "run-1",
        executionId: "forge-execution-1",
        status: "completed",
      },
      {
        evidenceId: "evidence-old",
        runId: "run-1",
        repositoryId: "repo-1",
        source: "github_actions",
        externalRunId: "github-old",
        commitSha: "old000",
        workflow: "CI",
        conclusion: "success",
        checks: [{ name: "typecheck", status: "passed", artifactIds: [] }],
        smokeTests: [],
        healthChecks: [],
        observedAt: "2026-09-21T10:00:00.000Z",
      },
    ]);
    await expect(
      instance.run({ payload: correlatedParams } as never, step),
    ).rejects.toThrow("commit SHA does not match");
  });
});
