import { afterEach, describe, expect, it, vi } from "vitest";
import {
  recordAuthAuditEvent,
  recordAuthMetric,
  safeAuthProvider,
  safeAuthReason,
} from "../src/auth/observability.js";

describe("authentication observability", () => {
  afterEach(() => vi.restoreAllMocks());

  it("keeps audit details to an allow-listed, secret-free shape", async () => {
    let bound: unknown[] = [];
    const db = {
      prepare: () => ({
        bind: (...values: unknown[]) => {
          bound = values;
          return { run: async () => ({ success: true }) };
        },
      }),
    } as unknown as D1Database;
    await recordAuthAuditEvent(db, {
      action: "auth.sign_in_failure",
      outcome: "failure",
      userId: "user-1",
      sessionId: "session-1",
      provider: "github",
      reason: "invalid_credentials",
      operation: "sign_in",
    });
    const details = JSON.parse(String(bound[6])) as Record<string, string>;
    expect(details).toEqual({
      provider: "github",
      reason: "invalid_credentials",
      operation: "sign_in",
    });
    expect(JSON.stringify(bound)).not.toContain("access_token");
    expect(JSON.stringify(bound)).not.toContain("refresh_token");
  });

  it("rejects unknown providers and reasons", () => {
    expect(safeAuthProvider("evil-provider")).toBeUndefined();
    expect(safeAuthReason("raw-oauth-error")).toBe("unknown");
  });

  it("emits provider failure metrics without user or token data", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    recordAuthMetric("google", "failure", "csrf_rejected");
    expect(warn).toHaveBeenCalledOnce();
    const payload = JSON.parse(String(warn.mock.calls[0]?.[0])) as Record<
      string,
      string
    >;
    expect(payload).toEqual({
      metric: "conclave.auth.sign_in",
      provider: "google",
      outcome: "failure",
      reason: "csrf_rejected",
    });
    expect(String(warn.mock.calls[0]?.[0])).not.toContain("user");
    expect(String(warn.mock.calls[0]?.[0])).not.toContain("token");
  });
});
