import { describe, expect, it } from "vitest";
import { PlanResultSchema } from "@conclave/protocol";
import {
  executeTaskGraph,
  TaskGraphState,
  validateTaskGraph,
} from "../src/index.js";

const plan = PlanResultSchema.parse({
  protocol: "conclave.protocol",
  version: "0.1",
  messageId: "plan-1",
  goalId: "goal-1",
  runId: "run-1",
  workerId: "lead-1",
  createdAt: "2026-09-21T10:00:00.000Z",
  messageType: "PlanResult",
  payload: {
    phases: [
      {
        phaseId: "phase-1",
        name: "Foundation",
        purpose: "Build the base",
        tasks: [
          {
            taskId: "task-a",
            objective: "A",
            role: "specialist",
            capabilities: ["a"],
            dependsOnTaskIds: [],
            requiresIndependentVerification: false,
          },
          {
            taskId: "task-b",
            objective: "B",
            role: "specialist",
            capabilities: ["b"],
            dependsOnTaskIds: ["task-a"],
            requiresIndependentVerification: false,
          },
        ],
      },
      {
        phaseId: "phase-2",
        name: "Parallel work",
        purpose: "Use the base",
        tasks: [
          {
            taskId: "task-c",
            objective: "C",
            role: "specialist",
            capabilities: ["c"],
            dependsOnTaskIds: ["task-a"],
            requiresIndependentVerification: false,
          },
        ],
      },
      {
        phaseId: "phase-3",
        name: "Finish",
        purpose: "Combine work",
        tasks: [
          {
            taskId: "task-d",
            objective: "D",
            role: "specialist",
            capabilities: ["d"],
            dependsOnTaskIds: ["task-b", "task-c"],
            requiresIndependentVerification: false,
          },
        ],
      },
    ],
    assumptions: [],
    risks: [],
  },
});

describe("Core task graph", () => {
  it("validates and executes multiple dependent tasks with deterministic retries", async () => {
    const graph = validateTaskGraph(plan);
    const state = new TaskGraphState(graph, {
      maxAttemptsPerTask: 2,
      maxTotalAttempts: 10,
      maxCostMicros: 100,
      timeoutMs: 100,
    });
    const executionOrder: string[] = [];
    let bAttempts = 0;

    const snapshot = await executeTaskGraph(
      state,
      async (task) => {
        executionOrder.push(task.taskId);
        if (task.taskId === "task-b" && bAttempts++ === 0) {
          return { outcome: "failed", failureClass: "worker", costMicros: 1 };
        }
        return { outcome: "succeeded", costMicros: 1 };
      },
      () => "2026-09-21T10:01:00.000Z",
    );

    expect(executionOrder).toEqual([
      "task-a",
      "task-b",
      "task-b",
      "task-c",
      "task-d",
    ]);
    expect(snapshot.runStatus).toBe("succeeded");
    expect(snapshot.tasks.every((task) => task.status === "succeeded")).toBe(
      true,
    );
    expect(snapshot.totalAttempts).toBe(5);
  });

  it("rejects unknown dependencies and cycles before Core creates state", () => {
    const unknown = structuredClone(plan);
    unknown.payload.phases[0]!.tasks[1]!.dependsOnTaskIds = ["missing"];
    expect(() => validateTaskGraph(unknown)).toThrow("Unknown dependency");

    const cycle = structuredClone(plan);
    cycle.payload.phases[0]!.tasks[0]!.dependsOnTaskIds = ["task-b"];
    expect(() => validateTaskGraph(cycle)).toThrow("cycle");
  });

  it("enforces retries, timeouts, cancellation, and reopening", () => {
    const state = new TaskGraphState(validateTaskGraph(plan), {
      maxAttemptsPerTask: 1,
      maxTotalAttempts: 2,
      maxCostMicros: 10,
      timeoutMs: 10,
    });
    state.startTask("task-a", "2026-09-21T10:00:00.000Z");
    state.timeoutTasks(
      Date.parse("2026-09-21T10:00:00.011Z"),
      "2026-09-21T10:00:00.011Z",
    );
    expect(state.snapshot().tasks[0]?.status).toBe("failed");
    expect(state.snapshot().runStatus).toBe("failed");

    state.reopenTask("task-a");
    expect(state.snapshot().runStatus).toBe("active");
    expect(state.snapshot().tasks[0]?.status).toBe("pending");
    state.cancelRun();
    expect(state.snapshot().runStatus).toBe("cancelled");
    expect(state.snapshot().tasks[0]?.status).toBe("cancelled");
  });
});
