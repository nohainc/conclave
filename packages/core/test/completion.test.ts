import { describe, expect, it } from "vitest";
import { CompletionCriteriaGate } from "../src/index.js";

const criteria = [
  {
    id: "c1",
    description: "Build passes",
    verificationRequirement: "executable_check",
    status: "pending" as const,
    evidenceArtifactIds: [],
    verifiedByWorkerId: null,
    verificationId: null,
  },
  {
    id: "c2",
    description: "Review passes",
    verificationRequirement: "independent_review",
    status: "pending" as const,
    evidenceArtifactIds: [],
    verifiedByWorkerId: null,
    verificationId: null,
  },
];

describe("CompletionCriteriaGate", () => {
  it("requires every criterion to be verified individually", () => {
    const gate = new CompletionCriteriaGate(criteria);
    gate.recordVerification({
      criterionId: "c1",
      method: "executable_check",
      outcome: "passed",
      verificationId: "v1",
      verifierWorkerId: "worker-1",
      evidenceArtifactIds: ["a1"],
    });
    expect(() => gate.assertAllVerified()).toThrow("c2");
    gate.recordVerification({
      criterionId: "c2",
      method: "independent_review",
      outcome: "passed",
      verificationId: "v2",
      verifierWorkerId: "worker-2",
      evidenceArtifactIds: ["a2"],
    });
    gate.assertCompletionClaim([
      { criterionId: "c1", status: "satisfied" },
      { criterionId: "c2", status: "satisfied" },
    ]);
  });

  it("rejects incomplete or extra model claims", () => {
    const gate = new CompletionCriteriaGate(criteria);
    expect(() =>
      gate.assertCompletionClaim([
        { criterionId: "c1", status: "satisfied" },
        { criterionId: "other", status: "satisfied" },
      ]),
    ).toThrow();
  });
});
