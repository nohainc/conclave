import { describe, expect, it } from "vitest";
import {
  assertSingleHostForgeBindings,
  resolveForgeExecutionMode,
  type ForgeWorkerBinding,
} from "../src/forge-execution.js";

function binding(id: string, agentId = "agent-mac"): ForgeWorkerBinding {
  return {
    worker: {
      id,
      workspaceId: "workspace-1",
      agentId,
      workerCatalogId: "plugin-test",
      workerVersionPolicy: "latest",
      name: id,
      capabilities: ["planning", "repository_write", "code_review"],
      roles: ["architect", "implementer", "reviewer"],
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

describe("single-worker Forge policy", () => {
  it("does not permit the retired direct cloud execution mode", () => {
    expect(() => resolveForgeExecutionMode("cloud_api")).toThrow(
      "direct cloud model execution has been retired",
    );
  });
  it("requires three workers on the same Host", () => {
    expect(() =>
      assertSingleHostForgeBindings([
        binding("lead"),
        binding("implementer"),
        binding("reviewer"),
      ]),
    ).not.toThrow();
  });
  it("rejects workers split across Hosts", () => {
    expect(() =>
      assertSingleHostForgeBindings([
        binding("lead"),
        binding("implementer"),
        binding("reviewer", "agent-linux"),
      ]),
    ).toThrow(/one Host/);
  });
});
