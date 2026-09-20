import { describe, expect, it } from "vitest";
import { InMemoryWorkerRegistry, type WorkerResource } from "../src/index.js";

const worker = (overrides: Partial<WorkerResource> = {}): WorkerResource => ({
  id: "worker-1",
  name: "Review worker",
  type: "model",
  provider: "provider-a",
  adapterVersion: "1",
  capabilities: ["code_review"],
  roles: ["reviewer"],
  permissions: ["repository_read"],
  availability: "available",
  cost: {
    currency: "USD",
    estimatedCostMicrosPerAttempt: 100,
    inputMicrosPerMillionTokens: 100,
    outputMicrosPerMillionTokens: 100,
  },
  executionEnvironment: "cloud",
  ...overrides,
});

describe("worker registry", () => {
  it("resolves by capability without provider-specific routing", () => {
    const registry = new InMemoryWorkerRegistry();
    registry.upsert(worker());

    expect(registry.resolve({ capability: "code_review" })?.id).toBe(
      "worker-1",
    );
  });

  it("filters role, permission, environment, and availability", () => {
    const registry = new InMemoryWorkerRegistry();
    registry.upsert(worker({ id: "busy", availability: "busy" }));
    registry.upsert(worker({ id: "local", executionEnvironment: "local" }));
    registry.upsert(
      worker({
        id: "eligible",
        roles: ["reviewer"],
        permissions: ["repository_read"],
      }),
    );

    expect(
      registry.resolve({
        capability: "code_review",
        role: "reviewer",
        permission: "repository_read",
        executionEnvironment: "cloud",
      })?.id,
    ).toBe("eligible");
  });

  it("selects the lowest configured cost and returns null when none match", () => {
    const registry = new InMemoryWorkerRegistry();
    registry.upsert(
      worker({
        id: "expensive",
        cost: { ...worker().cost, estimatedCostMicrosPerAttempt: 500 },
      }),
    );
    registry.upsert(
      worker({
        id: "cheap",
        cost: { ...worker().cost, estimatedCostMicrosPerAttempt: 50 },
      }),
    );

    expect(registry.resolve({ capability: "code_review" })?.id).toBe("cheap");
    expect(
      registry.resolve({
        capability: "code_review",
        maxEstimatedCostMicrosPerAttempt: 10,
      }),
    ).toBeNull();
  });
});
