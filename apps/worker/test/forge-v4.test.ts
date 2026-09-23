import { describe, expect, it } from "vitest";
import {
  assertV4BudgetAvailable,
  assertV4ForgeBindings,
  type ForgeWorkerBinding,
} from "../src/forge-execution.js";

class BudgetDb {
  prepare(query: string) {
    const statement = {
      bind: (...values: unknown[]) => {
        void values;
        return statement;
      },
      all: async <T>() => ({
        results: (query.includes("SELECT id, project_id")
          ? [
              {
                id: "budget-1",
                project_id: "project-a",
                run_id: null,
                credential_profile_id: "account-a",
                max_input_tokens: 10,
                max_output_tokens: null,
                max_cost_micros: null,
              },
            ]
          : []) as T[],
      }),
      first: async <T>() =>
        ({ input_tokens: 10, output_tokens: 0, cost_micros: null }) as T,
      run: async () => ({ success: true as const }),
    };
    return statement;
  }
  async batch() {
    return [];
  }
}

function binding(
  workerId: string,
  hostId: string,
  credentialProfileId: string,
): ForgeWorkerBinding {
  return {
    worker: {} as ForgeWorkerBinding["worker"],
    agent: {} as ForgeWorkerBinding["agent"],
    executionTarget: {
      workerId,
      hostId,
      credentialProfileId,
      resolvedWorkerVersion: "1.0.0",
      config: {},
    },
  };
}

describe("V4 Forge execution targets", () => {
  it("requires Host, Worker, and Credential Profile snapshots", () => {
    expect(() =>
      assertV4ForgeBindings([
        binding("codex", "host-a", "account-a"),
        binding("claude", "host-a", "account-b"),
        binding("openai", "host-b", "account-c"),
      ]),
    ).not.toThrow();
  });

  it("rejects legacy bindings without an immutable v4 target", () => {
    expect(() =>
      assertV4ForgeBindings([
        { worker: {} as never, agent: {} as never },
        { worker: {} as never, agent: {} as never },
        { worker: {} as never, agent: {} as never },
      ]),
    ).toThrow("Host + Worker + Credential Profile");
  });

  it("permits same Host with different accounts and multi-Host execution", () => {
    expect(() =>
      assertV4ForgeBindings([
        binding("codex", "host-a", "account-a"),
        binding("codex", "host-a", "account-b"),
        binding("claude", "host-b", "account-c"),
      ]),
    ).not.toThrow();
  });

  it("rejects a v4 assignment before dispatch when a scoped budget is exhausted", async () => {
    await expect(
      assertV4BudgetAvailable({
        db: new BudgetDb(),
        workspaceId: "workspace-a",
        projectId: "project-a",
        runId: "run-a",
        credentialProfileId: "account-a",
        inputTokens: 1,
        estimatedCostMicros: null,
      }),
    ).rejects.toThrow("rejects input token usage");
  });
});
