import { describe, expect, it } from "vitest";
import {
  HeadlessRunner,
  InMemoryExtensionRegistry,
  validateWorkflowTemplate,
  type WorkflowTemplate,
} from "../src/index.js";

const template: WorkflowTemplate = {
  protocol: "conclave.workflow",
  version: 1,
  id: "template.demo",
  name: "Demo extensibility flow",
  steps: [
    {
      id: "research",
      kind: "agent",
      agentId: "researcher",
      objective: "research",
      input: null,
    },
    {
      id: "approve",
      kind: "approval",
      prompt: "Proceed?",
      dependsOn: ["research"],
    },
    {
      id: "test",
      kind: "ci",
      workerId: "ci-1",
      command: ["test"],
      dependsOn: ["approve"],
    },
    {
      id: "publish",
      kind: "tool",
      toolId: "publisher",
      input: null,
      dependsOn: ["test"],
    },
  ],
};

describe("ecosystem SDK", () => {
  it("rejects workflow cycles and unknown dependencies", () => {
    expect(() =>
      validateWorkflowTemplate({
        ...template,
        steps: [{ ...template.steps[0], dependsOn: ["missing"] }],
      } as WorkflowTemplate),
    ).toThrow("Unknown dependency");
    expect(() =>
      validateWorkflowTemplate({
        ...template,
        steps: [
          { ...template.steps[0], dependsOn: ["publish"] },
          ...template.steps.slice(1),
        ],
      } as WorkflowTemplate),
    ).toThrow("cycle");
  });

  it("runs headless workflows and pauses for human approval", async () => {
    const order: string[] = [];
    const runner = new HeadlessRunner({
      template,
      handlers: {
        provider: async () => null,
        agent: async (step) => {
          order.push(step.id);
          return { findings: 1 };
        },
        tool: async (step) => {
          order.push(step.id);
          return { published: true };
        },
        ci: async (step) => {
          order.push(step.id);
          return { passed: [...step.command] };
        },
      },
    });
    await expect(runner.start()).resolves.toMatchObject({
      status: "awaiting_approval",
      completedStepIds: ["research"],
    });
    await expect(runner.approve(true)).resolves.toMatchObject({
      status: "completed",
      completedStepIds: ["research", "approve", "test", "publish"],
    });
    expect(order).toEqual(["research", "test", "publish"]);
  });

  it("supports cancellation and extension registration", async () => {
    const registry = new InMemoryExtensionRegistry();
    registry.registerTool({
      descriptor: { id: "tool", name: "Tool", version: "1", capabilities: [] },
      requiredPermissions: [],
      execute: async () => null,
    });
    expect(registry.tool("tool")?.descriptor.name).toBe("Tool");
    const runner = new HeadlessRunner({
      template,
      handlers: {
        provider: async () => null,
        agent: async () => null,
        ci: async () => null,
        tool: async () => null,
      },
    });
    expect(runner.cancel().status).toBe("cancelled");
    await expect(runner.start()).resolves.toMatchObject({
      status: "cancelled",
    });
  });
});
