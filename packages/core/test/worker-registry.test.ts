import { describe, expect, it } from "vitest";
import {
  InMemoryWorkerRegistry,
  type ConnectionResource,
  type WorkerResource,
} from "../src/index.js";

const connection = (
  id: string,
  overrides: Partial<ConnectionResource> = {},
): ConnectionResource => ({
  id,
  name: `${id}-connection`,
  transport: "provider_api",
  provider: "provider-a",
  adapterVersion: "1",
  authMode: "api_key",
  billingMode: "api_metered",
  cost: {
    currency: "USD",
    estimatedCostMicrosPerAttempt: 100,
    inputMicrosPerMillionTokens: 100,
    outputMicrosPerMillionTokens: 100,
  },
  executionEnvironment: "cloud",
  availability: "available",
  ...overrides,
});

const worker = (overrides: Partial<WorkerResource> = {}): WorkerResource => ({
  id: "worker-1",
  name: "Review worker",
  type: "model",
  capabilities: ["code_review"],
  roles: ["reviewer"],
  permissions: ["repository_read"],
  independenceKey: "provider-a",
  connectionIds: ["connection-1"],
  availability: "available",
  ...overrides,
});

function register(
  registry: InMemoryWorkerRegistry,
  resource: WorkerResource,
  connectionResource = connection(resource.connectionIds[0] ?? "connection-1"),
): void {
  registry.upsert(resource, [connectionResource]);
}

describe("worker registry", () => {
  it("resolves by capability without provider-specific worker identity", () => {
    const registry = new InMemoryWorkerRegistry();
    register(registry, worker());

    expect(registry.resolve({ capability: "code_review" })?.worker.id).toBe(
      "worker-1",
    );
  });

  it("filters role, permission, environment, and availability", () => {
    const registry = new InMemoryWorkerRegistry();
    register(registry, worker({ id: "busy", availability: "busy" }));
    register(
      registry,
      worker({ id: "local", connectionIds: ["local-connection"] }),
      connection("local-connection", { executionEnvironment: "local" }),
    );
    register(registry, worker({ id: "eligible" }));

    expect(
      registry.resolve({
        capability: "code_review",
        role: "reviewer",
        permission: "repository_read",
        executionEnvironment: "cloud",
      })?.worker.id,
    ).toBe("eligible");
  });

  it("selects the lowest connection cost and returns null when none match", () => {
    const registry = new InMemoryWorkerRegistry();
    register(
      registry,
      worker({ id: "expensive", connectionIds: ["expensive-connection"] }),
      connection("expensive-connection", {
        cost: { ...connection("x").cost, estimatedCostMicrosPerAttempt: 500 },
      }),
    );
    register(
      registry,
      worker({ id: "cheap", connectionIds: ["cheap-connection"] }),
      connection("cheap-connection", {
        cost: { ...connection("x").cost, estimatedCostMicrosPerAttempt: 50 },
      }),
    );

    expect(registry.resolve({ capability: "code_review" })?.worker.id).toBe(
      "cheap",
    );
    expect(
      registry.resolve({
        capability: "code_review",
        maxEstimatedCostMicrosPerAttempt: 10,
      }),
    ).toBeNull();
  });
});
