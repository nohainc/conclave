import { describe, expect, it } from "vitest";
import { assertMultiAgentForgeBindings } from "../src/forge-execution.js";
import type { WorkerBinding } from "@conclave/core";

function binding(id: string): WorkerBinding {
  return {
    worker: {
      id,
      name: id,
      type: "agent",
      capabilities: ["repository_read", "repository_write", "code_review"],
      roles: ["researcher", "implementer", "reviewer"],
      permissions: [],
      independenceKey: id,
      connectionIds: [`connection-${id}`],
      availability: "available",
    },
    connection: {
      id: `connection-${id}`,
      name: id,
      transport: "local_agent",
      provider: null,
      adapterVersion: "1",
      authMode: "local_session",
      billingMode: "subscription",
      cost: { estimatedCostMicrosPerAttempt: null },
      executionEnvironment: "local",
      availability: "available",
    },
  };
}

describe("multi-agent Forge policy", () => {
  it("accepts distributed local workers", () => {
    expect(() => assertMultiAgentForgeBindings(
      [binding("lead"), binding("implementer"), binding("reviewer")],
      new Map([
        ["lead", "agent-macbook"],
        ["implementer", "agent-macbook"],
        ["reviewer", "agent-linux"],
      ]),
    )).not.toThrow();
  });

  it("rejects a single Agent topology", () => {
    expect(() => assertMultiAgentForgeBindings(
      [binding("lead"), binding("implementer"), binding("reviewer")],
      new Map([
        ["lead", "agent-macbook"],
        ["implementer", "agent-macbook"],
        ["reviewer", "agent-macbook"],
      ]),
    )).toThrow(/at least two Agents/);
  });
});
