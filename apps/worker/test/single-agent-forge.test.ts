import { describe, expect, it } from "vitest";
import { assertSingleAgentForgeBindings } from "../src/forge-execution.js";
import type { WorkerBinding } from "@conclave/core";

function binding(id: string, transport: "local_agent" | "provider_api"): WorkerBinding {
  return {
    worker: {
      id,
      name: id,
      type: "agent",
      capabilities: ["planning", "repository_write", "code_review"],
      roles: ["architect", "implementer", "reviewer"],
      permissions: [],
      independenceKey: id,
      connectionIds: [`connection-${id}`],
      availability: "available",
    },
    connection: {
      id: `connection-${id}`,
      name: id,
      transport,
      provider: transport === "provider_api" ? "openai" : null,
      adapterVersion: "1",
      authMode: transport === "provider_api" ? "api_key" : "local_session",
      billingMode: transport === "provider_api" ? "api_metered" : "subscription",
      cost: { estimatedCostMicrosPerAttempt: null },
      executionEnvironment: "local",
      availability: "available",
    },
  };
}

describe("single-agent Forge policy", () => {
  it("requires three local workers on the same Agent", () => {
    const bindings = [binding("lead", "local_agent"), binding("implementer", "local_agent"), binding("reviewer", "local_agent")];
    expect(() => assertSingleAgentForgeBindings(bindings, new Map([
      ["lead", "agent-mac"],
      ["implementer", "agent-mac"],
      ["reviewer", "agent-mac"],
    ]))).not.toThrow();
  });

  it("rejects provider API workers", () => {
    const bindings = [binding("lead", "local_agent"), binding("implementer", "provider_api"), binding("reviewer", "local_agent")];
    expect(() => assertSingleAgentForgeBindings(bindings, new Map([
      ["lead", "agent-mac"],
      ["implementer", "agent-mac"],
      ["reviewer", "agent-mac"],
    ]))).toThrow(/direct cloud model workers/);
  });

  it("rejects workers split across Agents", () => {
    const bindings = [binding("lead", "local_agent"), binding("implementer", "local_agent"), binding("reviewer", "local_agent")];
    expect(() => assertSingleAgentForgeBindings(bindings, new Map([
      ["lead", "agent-mac"],
      ["implementer", "agent-mac"],
      ["reviewer", "agent-linux"],
    ]))).toThrow(/one Agent/);
  });
});
