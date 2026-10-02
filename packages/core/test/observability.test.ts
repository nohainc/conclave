import { describe, expect, it } from "vitest";
import {
  computeObservabilityMetrics,
  AUDIT_ACTIONS,
} from "../src/index.js";

describe("observability", () => {
  it("computes iteration timing, recovery, rollback, and utilization", () => {
    const metrics = computeObservabilityMetrics([
      {
        workspaceId: "w1",
        activeAtSample: true,
        queueEnteredAt: "2026-01-01T00:00:00.000Z",
        startedAt: "2026-01-01T00:00:02.000Z",
        finishedAt: "2026-01-01T00:00:07.000Z",
        checkoutRecoveryAttempted: true,
        checkoutRecoverySucceeded: true,
        rollbackAttempted: true,
        rollbackSucceeded: false,
      },
      {
        workspaceId: "w2",
        activeAtSample: false,
        checkoutRecoveryAttempted: true,
        checkoutRecoverySucceeded: false,
      },
    ]);
    expect(metrics.queueWaitMs).toBe(2000);
    expect(metrics.statefulDurationMs).toBe(5000);
    expect(metrics.checkoutRecoveryRate).toBe(0.5);
    expect(metrics.failedRollbackRate).toBe(1);
    expect(metrics.workspaceUtilization).toBe(0.5);
  });

  it("includes current Workstream and Profile audit actions", () => {
    expect(AUDIT_ACTIONS).toEqual(
      expect.arrayContaining(["discussion.moderated", "integration.updated", "profile.selected"]),
    );
  });
});
