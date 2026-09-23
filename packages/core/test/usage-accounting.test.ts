import { describe, expect, it } from "vitest";
import { evaluateBudget } from "../src/usage-accounting.js";

describe("shared-account usage accounting", () => {
  const current = {
    inputTokens: 100,
    outputTokens: 50,
    knownCostMicros: 2_000,
  };

  it("attributes a shared account without treating the owner as the requester", () => {
    const usage = {
      requesterUserId: "user-consumer",
      credentialProfileOwnerId: "user-owner",
      credentialProfileId: "profile-shared",
    };
    expect(usage).toMatchObject({
      requesterUserId: "user-consumer",
      credentialProfileOwnerId: "user-owner",
    });
  });

  it("rejects usage that would exceed a token or monetary budget", () => {
    expect(
      evaluateBudget(
        { maxInputTokens: 150, maxOutputTokens: 100, maxCostMicros: 5_000 },
        current,
        { inputTokens: 51, outputTokens: 1, costMicros: 100 },
      ),
    ).toEqual({ allowed: false, reason: "input_tokens" });
    expect(
      evaluateBudget(
        { maxInputTokens: null, maxOutputTokens: null, maxCostMicros: 2_050 },
        current,
        { inputTokens: 0, outputTokens: 0, costMicros: 51 },
      ),
    ).toEqual({ allowed: false, reason: "cost" });
  });

  it("does not invent subscription cost when the provider gives none", () => {
    expect(
      evaluateBudget(
        { maxInputTokens: null, maxOutputTokens: null, maxCostMicros: 10_000 },
        current,
        { inputTokens: 1, outputTokens: 1, costMicros: null },
      ),
    ).toEqual({ allowed: false, reason: "cost_unknown" });
    expect(
      evaluateBudget(
        { maxInputTokens: 1_000, maxOutputTokens: 1_000, maxCostMicros: null },
        current,
        { inputTokens: 1, outputTokens: 1, costMicros: null },
      ),
    ).toEqual({ allowed: true });
  });
});
