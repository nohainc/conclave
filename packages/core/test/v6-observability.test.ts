import { describe, expect, it } from "vitest";
import {
  computeV6ObservabilityMetrics,
  validateV6UsageDimensions,
} from "../src/index.js";

describe("v6 observability", () => {
  it("requires complete usage attribution", () => {
    expect(() => validateV6UsageDimensions({
      projectId: "p", workstreamId: "s", workRequestId: "r", requesterUserId: "u",
      executionWorkspaceId: "w", workspaceOwnerUserId: "wo", workerId: "worker",
      accountId: "account", accountOwnerUserId: "ao", workflowVersionId: "wf",
      inputTokens: 2, outputTokens: 3, costMicros: 4, durationMs: 5,
    })).not.toThrow();
    expect(() => validateV6UsageDimensions({
      projectId: "", workstreamId: "s", workRequestId: "r", requesterUserId: "u",
      executionWorkspaceId: "w", workspaceOwnerUserId: "wo", workerId: "worker",
      accountId: "account", accountOwnerUserId: "ao", workflowVersionId: "wf",
      inputTokens: 0, outputTokens: 0, costMicros: null, durationMs: 0,
    })).toThrow(/projectId/);
  });

  it("computes iteration timing, recovery, rollback, and utilization", () => {
    const metrics = computeV6ObservabilityMetrics([
      {
        workspaceId: "w1", activeAtSample: true,
        queueEnteredAt: "2026-01-01T00:00:00.000Z", startedAt: "2026-01-01T00:00:02.000Z", finishedAt: "2026-01-01T00:00:07.000Z",
        checkoutRecoveryAttempted: true, checkoutRecoverySucceeded: true,
        rollbackAttempted: true, rollbackSucceeded: false,
      },
      { workspaceId: "w2", activeAtSample: false, checkoutRecoveryAttempted: true, checkoutRecoverySucceeded: false },
    ]);
    expect(metrics.queueWaitMs).toBe(2000);
    expect(metrics.statefulDurationMs).toBe(5000);
    expect(metrics.checkoutRecoveryRate).toBe(0.5);
    expect(metrics.failedRollbackRate).toBe(1);
    expect(metrics.workspaceUtilization).toBe(0.5);
  });
});
