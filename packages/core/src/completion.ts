export interface CompletionCriterionState {
  readonly id: string;
  readonly description: string;
  readonly verificationRequirement: string;
  readonly status: "pending" | "verified" | "failed" | "waived";
  readonly evidenceArtifactIds: readonly string[];
  readonly verifiedByWorkerId: string | null;
  readonly verificationId: string | null;
}

export class CompletionCriteriaGate {
  private readonly criteria = new Map<string, CompletionCriterionState>();

  constructor(criteria: readonly CompletionCriterionState[]) {
    if (criteria.length === 0)
      throw new Error("A goal must define completion criteria");
    for (const criterion of criteria) {
      if (this.criteria.has(criterion.id))
        throw new Error(`Duplicate completion criterion: ${criterion.id}`);
      this.criteria.set(criterion.id, { ...criterion });
    }
  }

  list(): readonly CompletionCriterionState[] {
    return [...this.criteria.values()];
  }

  recordVerification(input: {
    readonly criterionId: string;
    readonly method: string;
    readonly outcome: "passed" | "failed" | "waived" | "inconclusive";
    readonly verificationId: string;
    readonly verifierWorkerId: string;
    readonly evidenceArtifactIds: readonly string[];
  }): void {
    const criterion = this.criteria.get(input.criterionId);
    if (!criterion)
      throw new Error(`Unknown completion criterion: ${input.criterionId}`);
    if (input.method !== criterion.verificationRequirement)
      throw new Error(
        `Verification method does not satisfy criterion ${input.criterionId}`,
      );
    const status =
      input.outcome === "passed"
        ? "verified"
        : input.outcome === "waived"
          ? "waived"
          : "failed";
    this.criteria.set(input.criterionId, {
      ...criterion,
      status,
      evidenceArtifactIds: [...input.evidenceArtifactIds],
      verifiedByWorkerId: input.verifierWorkerId,
      verificationId: input.verificationId,
    });
  }

  assertAllVerified(): void {
    const missing = this.list().filter(
      (criterion) => criterion.status !== "verified",
    );
    if (missing.length > 0)
      throw new Error(
        `Completion criteria are not all verified: ${missing.map((c) => c.id).join(", ")}`,
      );
  }

  assertCompletionClaim(
    claims: readonly {
      readonly criterionId: string;
      readonly status: string;
    }[],
  ): void {
    const expected = new Set(this.criteria.keys());
    const actual = new Set(claims.map((claim) => claim.criterionId));
    if (
      actual.size !== expected.size ||
      [...expected].some((id) => !actual.has(id))
    )
      throw new Error(
        "Completion report does not cover exactly the goal's completion criteria",
      );
    if (claims.some((claim) => claim.status !== "satisfied"))
      throw new Error("Completion report contains an unsatisfied criterion");
    this.assertAllVerified();
  }
}
