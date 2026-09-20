import { describe, expect, it } from "vitest";
import {
  AuthorizationError,
  BudgetExceededError,
  assertWithinBudget,
  authorize,
  consumeRateLimit,
  decryptCredential,
  encryptCredential,
  isRetained,
  retentionExpiresAt,
} from "../src/index.js";

describe("security primitives", () => {
  it("enforces organization and project permissions", () => {
    const context = {
      userId: "user-1",
      organizationId: "org-1",
      organizationRoles: ["member"] as const,
      projectRoles: { "project-1": ["reviewer"] as const },
    };
    authorize(context, "project:read", "project-1");
    expect(() => authorize(context, "run:create", "project-1")).toThrow(
      AuthorizationError,
    );
    expect(() => authorize(context, "project:read", "project-2")).toThrow(
      AuthorizationError,
    );
  });

  it("rejects usage that crosses a budget", () => {
    expect(() =>
      assertWithinBudget(
        { maxCostMicros: 100 },
        { inputTokens: 0, outputTokens: 0, costMicros: 90 },
        { inputTokens: 1, outputTokens: 1, costMicros: 11 },
      ),
    ).toThrow(BudgetExceededError);
  });

  it("limits requests within a fixed window", () => {
    const state = { count: 0, windowStartedAt: 1_000 };
    expect(
      consumeRateLimit(state, { requests: 1, windowSeconds: 60 }, 1_001)
        .allowed,
    ).toBe(true);
    expect(
      consumeRateLimit(state, { requests: 1, windowSeconds: 60 }, 1_002)
        .allowed,
    ).toBe(false);
    expect(
      consumeRateLimit(state, { requests: 1, windowSeconds: 60 }, 61_001)
        .allowed,
    ).toBe(true);
  });

  it("encrypts credentials without exposing plaintext", async () => {
    const key = await globalThis.crypto.subtle.generateKey(
      { name: "AES-GCM", length: 256 },
      false,
      ["encrypt", "decrypt"],
    );
    const envelope = await encryptCredential("super-secret", key, "kek-1");
    expect(JSON.stringify(envelope)).not.toContain("super-secret");
    await expect(decryptCredential(envelope, key)).resolves.toBe(
      "super-secret",
    );
  });

  it("calculates retention consistently", () => {
    const expiry = retentionExpiresAt("2026-01-01T00:00:00.000Z", 30);
    expect(isRetained(expiry, Date.parse("2026-01-15T00:00:00.000Z"))).toBe(
      true,
    );
    expect(isRetained(expiry, Date.parse("2026-02-01T00:00:00.000Z"))).toBe(
      false,
    );
  });
});
