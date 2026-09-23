import { describe, expect, it } from "vitest";
import {
  SENSITIVE_OPERATIONS,
  STEP_UP_REQUIREMENTS,
  isStepUpSatisfied,
  type StepUpRecord,
} from "../src/auth/step-up.js";

const now = new Date("2026-09-23T12:00:00.000Z");

function record(overrides: Partial<StepUpRecord> = {}): StepUpRecord {
  return {
    user_id: "user-1",
    session_id: "session-1",
    method: "passkey",
    authenticated_at: "2026-09-23T11:55:00.000Z",
    expires_at: "2026-09-23T12:05:00.000Z",
    ...overrides,
  };
}

describe("sensitive operation step-up policy", () => {
  it("declares a short fresh-auth window for every sensitive operation", () => {
    expect(Object.keys(STEP_UP_REQUIREMENTS)).toEqual([
      SENSITIVE_OPERATIONS.workspaceOwnershipTransfer,
      SENSITIVE_OPERATIONS.credentialProfileShare,
      SENSITIVE_OPERATIONS.hostRevoke,
      SENSITIVE_OPERATIONS.billingSecurityChange,
      SENSITIVE_OPERATIONS.apiCredentialShare,
    ]);
    expect(STEP_UP_REQUIREMENTS[SENSITIVE_OPERATIONS.hostRevoke].maxAgeMs).toBe(
      10 * 60 * 1000,
    );
  });

  it("accepts a fresh strong passkey proof", () => {
    expect(
      isStepUpSatisfied(record(), SENSITIVE_OPERATIONS.hostRevoke, now),
    ).toBe(true);
  });

  it("rejects missing, expired, stale, and unsupported proofs", () => {
    expect(
      isStepUpSatisfied(null, SENSITIVE_OPERATIONS.hostRevoke, now),
    ).toBe(false);
    expect(
      isStepUpSatisfied(
        record({ expires_at: "2026-09-23T11:59:59.000Z" }),
        SENSITIVE_OPERATIONS.hostRevoke,
        now,
      ),
    ).toBe(false);
    expect(
      isStepUpSatisfied(
        record({ authenticated_at: "2026-09-23T11:49:59.000Z" }),
        SENSITIVE_OPERATIONS.hostRevoke,
        now,
      ),
    ).toBe(false);
    expect(
      isStepUpSatisfied(
        record({ method: "totp" }),
        SENSITIVE_OPERATIONS.hostRevoke,
        now,
      ),
    ).toBe(true);
  });
});
