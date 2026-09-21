import { describe, expect, it } from "vitest";

import {
  InMemoryWorkerRegistry,
  estimatedSelectionCost,
  QualityRoutingError,
  resolveQuality,
  routeWorkers,
  type ConnectionResource,
  type WorkerResource,
} from "../src/index.js";

function register(
  registry: InMemoryWorkerRegistry,
  id: string,
  independenceKey: string,
  cost: number | null,
): void {
  const worker: WorkerResource = {
    id,
    name: id,
    type: "model",
    capabilities: ["repository_research"],
    roles: ["researcher"],
    permissions: ["repository_read"],
    independenceKey,
    connectionIds: [`${id}-connection`],
    availability: "available",
  };
  const connection: ConnectionResource = {
    id: `${id}-connection`,
    name: id,
    transport: "provider_api",
    provider: id,
    adapterVersion: "1",
    authMode: "api_key",
    billingMode: "api_metered",
    cost: {
      currency: "USD",
      estimatedCostMicrosPerAttempt: cost,
      inputMicrosPerMillionTokens: null,
      outputMicrosPerMillionTokens: null,
    },
    executionEnvironment: "cloud",
    availability: "available",
  };
  registry.upsert(worker, [connection]);
}

describe("quality presets and cost routing", () => {
  it("routes economy to the cheapest eligible connection", () => {
    const registry = new InMemoryWorkerRegistry();
    register(registry, "expensive", "provider-a", 400);
    register(registry, "cheap", "provider-b", 100);

    const selected = routeWorkers(
      registry,
      { capability: "repository_research", role: "researcher" },
      resolveQuality("economy"),
    );

    expect(selected.map((binding) => binding.worker.id)).toEqual(["cheap"]);
    expect(estimatedSelectionCost(selected)).toBe(100);
  });

  it("skips same-provider duplicates for high assurance", () => {
    const registry = new InMemoryWorkerRegistry();
    register(registry, "cheap-a", "same-provider", 10);
    register(registry, "cheap-b", "same-provider", 20);
    register(registry, "independent", "other-provider", 30);

    const selected = routeWorkers(
      registry,
      { capability: "repository_research", role: "researcher" },
      resolveQuality("high_assurance"),
    );

    expect(selected.map((binding) => binding.worker.id)).toEqual([
      "cheap-a",
      "independent",
    ]);
  });

  it("rejects a custom policy that exceeds the available cost ceiling", () => {
    const registry = new InMemoryWorkerRegistry();
    register(registry, "worker", "provider", 1_000);

    expect(() =>
      routeWorkers(
        registry,
        { capability: "repository_research", role: "researcher" },
        resolveQuality("custom", {
          mode: "single",
          candidateCount: 1,
          maxEstimatedCostMicrosPerAttempt: 500,
        }),
      ),
    ).toThrow(QualityRoutingError);
  });
});
