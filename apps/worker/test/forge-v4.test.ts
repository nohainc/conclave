import { describe, expect, it } from "vitest";
import {
  assertV4ForgeBindings,
  type ForgeWorkerBinding,
} from "../src/forge-execution.js";

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
});
