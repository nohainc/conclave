import { describe, expect, it } from "vitest";
import {
  BUILT_IN_WORKFLOW_NAMES,
  BUILT_IN_WORKFLOW_VERSIONS,
  markWorkflowTaskResult,
  planWorkflowTasks,
  readyWorkflowTasks,
  validateWorkflowOutput,
  workflowExecutionBatches,
} from "../src/index.js";

describe("v6 workflow runner", () => {
  it("plans every immutable built-in version into dependency-preserving Tasks", () => {
    for (const name of BUILT_IN_WORKFLOW_NAMES) {
      const version = BUILT_IN_WORKFLOW_VERSIONS[name];
      const tasks = planWorkflowTasks(version, `request-${name}`);
      expect(tasks).toHaveLength(version.steps.length);
      expect(tasks.every((task) => task.workflowVersionId === version.id)).toBe(
        true,
      );
      expect(
        workflowExecutionBatches(tasks)
          .flat()
          .map((task) => task.step.id),
      ).toHaveLength(version.steps.length);
      for (const task of tasks) {
        expect(task.dependencyTaskIds).toEqual(
          task.step.dependsOn.map((id) => `task-request-${name}-${id}`),
        );
      }
    }
  });

  it("routes ready independent stateless Tasks together but keeps stateful work ordered", () => {
    const tasks = planWorkflowTasks(
      {
        ...BUILT_IN_WORKFLOW_VERSIONS["Full Cycle"],
        steps: [
          {
            ...BUILT_IN_WORKFLOW_VERSIONS.Research.steps[0]!,
            id: "research-a",
          },
          {
            ...BUILT_IN_WORKFLOW_VERSIONS.Research.steps[0]!,
            id: "research-b",
            order: 1,
          },
          {
            ...BUILT_IN_WORKFLOW_VERSIONS.Implementation.steps[0]!,
            id: "implementation",
            order: 2,
            dependsOn: ["research-a"],
          },
        ],
      },
      "request-independent",
    );
    const batches = workflowExecutionBatches(tasks);
    expect(batches[0]?.map((task) => task.step.id)).toEqual([
      "research-a",
      "research-b",
    ]);
    expect(batches[1]?.map((task) => task.step.id)).toEqual(["implementation"]);
  });

  it("propagates failure and cancellation to dependent Tasks", () => {
    const tasks = planWorkflowTasks(
      BUILT_IN_WORKFLOW_VERSIONS["Full Cycle"],
      "request-failure",
    );
    const first = tasks[0]!;
    const failed = markWorkflowTaskResult(tasks, first.id, "failed");
    expect(
      failed.filter((task) => task.status === "failed").length,
    ).toBeGreaterThan(1);
    const cancelled = markWorkflowTaskResult(tasks, first.id, "cancelled");
    expect(cancelled.some((task) => task.status === "cancelled")).toBe(true);
    expect(readyWorkflowTasks(failed)).toHaveLength(0);
  });

  it("requires result-contract fields before admitting a completed Task", () => {
    const contract = {
      contentType: "application/json",
      requiredFields: ["summary"],
      artifactTypes: [],
    };
    expect(() =>
      validateWorkflowOutput({ summary: "done" }, contract),
    ).not.toThrow();
    expect(() => validateWorkflowOutput({}, contract)).toThrow("summary");
  });
});
