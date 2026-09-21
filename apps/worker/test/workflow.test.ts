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
});
