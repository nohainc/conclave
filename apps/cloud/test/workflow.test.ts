import { describe, expect, it } from "vitest";
import { ConclaveRunWorkflow } from "../src/workflow.js";
import { BUILT_IN_WORKFLOW_VERSIONS } from "@conclave/core";

function workflow(
  terminalEvents: readonly Record<string, unknown>[],
  executionId = "forge-execution-1",
  stepNames: string[] = [],
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
    ) => {
      stepNames.push(_name);
      return callback();
    },
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
  it("runs an immutable WorkflowVersion instead of fixed research/planning stages", async () => {
    const stepNames: string[] = [];
    const { instance, step } = workflow(
      [{
        eventId: "workflow-terminal-1",
        runId: "run-1",
        executionId: "forge-execution-1",
        status: "completed",
      }],
      "forge-execution-1",
      stepNames,
    );
    const result = await instance.run({
      payload: {
        ...params,
        workRequestId: "work-request-1",
        workflowVersion: BUILT_IN_WORKFLOW_VERSIONS.Research,
      },
    } as never, step);
    expect(result.stage).toBe("completed");
    expect(stepNames).toContain("workflow:research:execute:1");
    expect(stepNames).not.toContain("checkpoint:planning");
  });

  it("records durable phases before waiting for Forge terminal state", async () => {
    const stepNames: string[] = [];
    const { instance, step } = workflow(
      [
        {
          eventId: "forge-order-1",
          runId: "run-1",
          executionId: "forge-execution-1",
          status: "completed",
        },
      ],
      "forge-execution-1",
      stepNames,
    );

    await instance.run({ payload: params } as never, step);

    expect(stepNames).toEqual([
      "checkpoint:intake",
      "checkpoint:research",
      "checkpoint:planning",
      "checkpoint:implementation",
      "forge:execute",
      "forge:terminal:forge-order-1",
      "checkpoint:verification",
      "checkpoint:completed",
    ]);
  });

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

  it("reconciles a persisted Forge completion when the callback is lost", async () => {
    let waited = false;
    const service = {
      fetch: async (input: RequestInfo | URL) => {
        if (String(input).includes("/execute")) {
          return Response.json(
            { executionId: "forge-execution-1" },
            {
              status: 202,
            },
          );
        }
        return Response.json({
          executionId: "forge-execution-1",
          runId: "run-1",
          status: "completed",
          resultArtifactId: "artifact-reconciled",
        });
      },
    };
    const instance = new ConclaveRunWorkflow(
      {} as never,
      { CONCLAVE_FORGE_EXECUTION: service } as unknown as Env,
    );
    const step = {
      do: async <T>(
        _name: string,
        _config: unknown,
        callback: () => Promise<T>,
      ) => callback(),
      waitForEvent: async <T>() => {
        if (!waited) {
          waited = true;
          throw new Error("event wait timed out");
        }
        return { payload: undefined as T };
      },
      sleep: async () => undefined,
    } as unknown as import("cloudflare:workers").WorkflowStep;

    const result = await instance.run({ payload: params } as never, step);
    expect(result.stage).toBe("completed");
    expect(result.resultArtifactId).toBe("artifact-reconciled");
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

  it("reconciles a persisted reviewer timeout as a failed run", async () => {
    let waited = false;
    const service = {
      fetch: async (input: RequestInfo | URL) => {
        if (String(input).includes("/execute")) {
          return Response.json(
            { executionId: "forge-execution-timeout" },
            { status: 202 },
          );
        }
        return Response.json({
          executionId: "forge-execution-timeout",
          runId: "run-1",
          status: "failed",
          error: "reviewer timed out before independent verification",
        });
      },
    };
    const instance = new ConclaveRunWorkflow(
      {} as never,
      { CONCLAVE_FORGE_EXECUTION: service } as unknown as Env,
    );
    const step = {
      do: async <T>(
        _name: string,
        _config: unknown,
        callback: () => Promise<T>,
      ) => callback(),
      waitForEvent: async <T>() => {
        if (!waited) {
          waited = true;
          throw new Error("Forge callback wait timed out");
        }
        return { payload: undefined as T };
      },
      sleep: async () => undefined,
    } as unknown as import("cloudflare:workers").WorkflowStep;

    const result = await instance.run({ payload: params } as never, step);
    expect(result.stage).toBe("failed");
    expect(result.status).toBe("failed");
    expect(result.executionStatus).toBe("failed");
    expect(result.failureReason).toContain("reviewer timed out");
  });

  it("recovers after a Forge restart and transient network loss", async () => {
    let statusCalls = 0;
    let reconciliationRetries = 0;
    const service = {
      fetch: async (input: RequestInfo | URL) => {
        if (String(input).includes("/execute")) {
          return Response.json(
            { executionId: "forge-execution-restarted" },
            { status: 202 },
          );
        }
        statusCalls += 1;
        if (statusCalls === 1) {
          throw new Error("Forge service restarted while the network was down");
        }
        return Response.json({
          executionId: "forge-execution-restarted",
          runId: "run-1",
          status: "completed",
          resultArtifactId: "artifact-after-restart",
        });
      },
    };
    const instance = new ConclaveRunWorkflow(
      {} as never,
      { CONCLAVE_FORGE_EXECUTION: service } as unknown as Env,
    );
    const step = {
      do: async <T>(
        name: string,
        _config: unknown,
        callback: () => Promise<T>,
      ) => {
        if (name === "forge:reconcile:0") {
          while (true) {
            try {
              return await callback();
            } catch (error) {
              reconciliationRetries += 1;
              if (reconciliationRetries > 1) throw error;
            }
          }
        }
        return callback();
      },
      waitForEvent: async () => {
        throw new Error("terminal callback was lost during Forge restart");
      },
      sleep: async () => undefined,
    } as unknown as import("cloudflare:workers").WorkflowStep;

    const result = await instance.run({ payload: params } as never, step);

    expect(statusCalls).toBe(2);
    expect(reconciliationRetries).toBe(1);
    expect(result.stage).toBe("completed");
    expect(result.resultArtifactId).toBe("artifact-after-restart");
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
