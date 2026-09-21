import { describe, expect, it } from "vitest";
import {
  createIsolatedReviewContext,
  getVerificationPolicy,
  TaskGraphState,
  type ValidatedTaskGraph,
  VerificationGate,
} from "../src/index.js";

const graph: ValidatedTaskGraph = {
  phases: [{ phaseId: "phase-1", name: "Work", purpose: "Work", order: 0 }],
  tasks: [
    {
      taskId: "task-1",
      phaseId: "phase-1",
      phaseOrder: 0,
      taskOrder: 0,
      objective: "Work",
      role: "specialist",
      capabilities: ["work"],
      dependsOnTaskIds: [],
      requiresIndependentVerification: true,
    },
  ],
};

const limits = {
  maxAttemptsPerTask: 1,
  maxTotalAttempts: 2,
  maxCostMicros: 100,
  timeoutMs: 100,
};

const review = {
  verificationId: "verification-review",
  taskId: "task-1",
  method: "independent_review" as const,
  outcome: "passed" as const,
  verifierWorkerId: "reviewer-1",
  independent: true,
};

describe("independent verification", () => {
  it("requires isolated reviewer identity and context", () => {
    expect(() =>
      createIsolatedReviewContext({
        reviewContextId: "context-1",
        implementationContextId: "context-1",
        reviewerWorkerId: "reviewer-1",
        authorWorkerId: "implementer-1",
        artifactIds: [],
      }),
    ).toThrow("isolated context");
    expect(() =>
      createIsolatedReviewContext({
        reviewContextId: "review-1",
        implementationContextId: "implementation-1",
        reviewerWorkerId: "implementer-1",
        authorWorkerId: "implementer-1",
        artifactIds: [],
      }),
    ).toThrow("different worker");
  });

  it("blocks completion on a blocking finding until fix and re-review", () => {
    const state = new TaskGraphState(graph, {
      ...limits,
      verificationPolicy: getVerificationPolicy("standard"),
    });
    state.startTask("task-1", "2026-09-21T10:00:00.000Z");
    state.openFinding({
      findingId: "finding-1",
      taskId: "task-1",
      severity: "major",
      description: "Missing test",
      authorWorkerId: "implementer-1",
      status: "open",
    });
    state.recordVerification(review);
    expect(() =>
      state.completeTask("task-1", "2026-09-21T10:01:00.000Z", 1),
    ).toThrow("blocking_finding");
    state.fixFinding("finding-1");
    expect(() =>
      state.completeTask("task-1", "2026-09-21T10:01:00.000Z", 1),
    ).toThrow("blocking_finding");
    expect(() => state.verifyFinding("finding-1", "reviewer-1")).toThrow(
      "passed independent review",
    );
    state.recordVerification({
      ...review,
      verificationId: "verification-rereview",
    });
    state.verifyFinding("finding-1", "reviewer-1");
    expect(
      state.completeTask("task-1", "2026-09-21T10:02:00.000Z", 1).status,
    ).toBe("succeeded");
  });

  it("enforces high and critical policy methods", () => {
    const high = new VerificationGate(getVerificationPolicy("high"));
    high.recordVerification(review);
    expect(high.canComplete("task-1")).toBe(false);
    high.recordVerification({
      verificationId: "verification-test",
      taskId: "task-1",
      method: "executable_check",
      outcome: "passed",
      verifierWorkerId: "verifier-1",
      independent: false,
    });
    expect(high.canComplete("task-1")).toBe(true);

    const unauthorized = new VerificationGate(
      getVerificationPolicy("standard"),
    );
    unauthorized.openFinding({
      findingId: "finding-2",
      taskId: "task-1",
      severity: "major",
      description: "Needs review",
      authorWorkerId: "implementer-1",
      status: "open",
    });
    unauthorized.fixFinding("finding-2");
    unauthorized.recordVerification(review);
    expect(() =>
      unauthorized.verifyFinding("finding-2", "other-reviewer"),
    ).toThrow("passed independent review");

    const critical = new VerificationGate(getVerificationPolicy("critical"));
    critical.recordVerification(review);
    critical.recordVerification({
      verificationId: "verification-test",
      taskId: "task-1",
      method: "executable_check",
      outcome: "passed",
      verifierWorkerId: "verifier-1",
      independent: false,
    });
    expect(critical.canComplete("task-1")).toBe(false);
    critical.recordVerification({
      verificationId: "verification-approval",
      taskId: "task-1",
      method: "human_approval",
      outcome: "passed",
      verifierWorkerId: "human-1",
      independent: true,
    });
    expect(critical.canComplete("task-1")).toBe(true);
  });
});
