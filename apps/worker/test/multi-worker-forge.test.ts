import { describe, expect, it } from "vitest";
import {
  assertMultiWorkerForgeBindings,
  type ForgeWorkerBinding,
} from "../src/forge-execution.js";

function binding(id: string, agentId: string): ForgeWorkerBinding {
  return {
    worker: {
      id,
      workspaceId: "workspace-1",
      agentId,
      pluginId: "plugin-test",
      pluginVersionPolicy: "latest",
      name: id,
      capabilities: ["repository_read", "repository_write", "code_review"],
      roles: ["researcher", "implementer", "reviewer"],
      config: {},
      secretRefs: [],
      enabled: true,
      billingMode: "subscription",
      independenceKey: id,
      concurrencyLimit: 1,
      sessionPolicy: "stateless",
      availability: "available",
      createdAt: "2026-09-21T00:00:00.000Z",
      updatedAt: "2026-09-21T00:00:00.000Z",
    },
    agent: {
      id: agentId,
      workspaceId: "workspace-1",
      name: agentId,
      hostname: agentId,
      status: "online",
      version: "0.1.0",
      capabilities: {
        os: "macos",
        arch: "arm64",
        version: "0.1.0",
        supportedRuntimes: [],
        maxConcurrentWorkers: 3,
      },
      enrolledAt: "2026-09-21T00:00:00.000Z",
      lastHeartbeatAt: "2026-09-21T00:00:00.000Z",
      revokedAt: null,
    },
  };
}

describe("multi-worker Forge policy", () => {
  it("accepts distributed workers", () => {
    expect(() =>
      assertMultiWorkerForgeBindings([
        binding("lead", "agent-macbook"),
        binding("implementer", "agent-macbook"),
        binding("reviewer", "agent-linux"),
      ]),
    ).not.toThrow();
  });
  it("rejects a single Host topology", () => {
    expect(() =>
      assertMultiWorkerForgeBindings([
        binding("lead", "agent-macbook"),
        binding("implementer", "agent-macbook"),
        binding("reviewer", "agent-macbook"),
      ]),
    ).toThrow(/at least two Hosts/);
  });
});
