export type VerificationPolicyName = "standard" | "high" | "critical";
export type FindingSeverity = "blocker" | "major" | "minor" | "note";
export type FindingStatus =
  "open" | "fixed" | "verified" | "dismissed" | "reopened";
export type VerificationMethod =
  "independent_review" | "executable_check" | "human_approval";

export interface VerificationPolicy {
  readonly name: VerificationPolicyName;
  readonly independentReviewRequired: boolean;
  readonly executableCheckRequired: boolean;
  readonly humanApprovalRequired: boolean;
  readonly blockingSeverities: readonly FindingSeverity[];
}

const POLICIES: Record<VerificationPolicyName, VerificationPolicy> = {
  standard: {
    name: "standard",
    independentReviewRequired: true,
    executableCheckRequired: false,
    humanApprovalRequired: false,
    blockingSeverities: ["blocker", "major"],
  },
  high: {
    name: "high",
    independentReviewRequired: true,
    executableCheckRequired: true,
    humanApprovalRequired: false,
    blockingSeverities: ["blocker", "major"],
  },
  critical: {
    name: "critical",
    independentReviewRequired: true,
    executableCheckRequired: true,
    humanApprovalRequired: true,
    blockingSeverities: ["blocker", "major", "minor"],
  },
};

export function getVerificationPolicy(
  name: VerificationPolicyName,
): VerificationPolicy {
  return {
    ...POLICIES[name],
    blockingSeverities: [...POLICIES[name].blockingSeverities],
  };
}

export interface IsolatedReviewContext {
  readonly reviewContextId: string;
  readonly implementationContextId: string;
  readonly reviewerWorkerId: string;
  readonly authorWorkerId: string;
  readonly artifactIds: readonly string[];
}

export function createIsolatedReviewContext(
  input: IsolatedReviewContext,
): IsolatedReviewContext {
  if (input.reviewerWorkerId === input.authorWorkerId) {
    throw new Error("Independent review requires a different worker");
  }
  if (input.reviewContextId === input.implementationContextId) {
    throw new Error("Independent review requires an isolated context");
  }
  return { ...input, artifactIds: [...input.artifactIds] };
}

export interface Finding {
  readonly findingId: string;
  readonly taskId: string;
  readonly severity: FindingSeverity;
  readonly description: string;
  readonly authorWorkerId: string;
  readonly status: FindingStatus;
}

export interface VerificationRecord {
  readonly verificationId: string;
  readonly taskId: string;
  readonly method: VerificationMethod;
  readonly outcome: "passed" | "failed" | "inconclusive";
  readonly verifierWorkerId: string;
  readonly independent: boolean;
}

export function isBlockingFinding(
  finding: Finding,
  policy: VerificationPolicy,
): boolean {
  return (
    policy.blockingSeverities.includes(finding.severity) &&
    !["verified", "dismissed"].includes(finding.status)
  );
}

export class VerificationGate {
  private readonly findings = new Map<string, Finding>();
  private readonly verifications = new Map<
    string,
    VerificationRecord & { readonly sequence: number }
  >();
  private readonly fixedAfterVerificationSequence = new Map<string, number>();
  private verificationSequence = 0;

  constructor(readonly policy: VerificationPolicy) {}

  openFinding(finding: Finding): void {
    if (this.findings.has(finding.findingId)) {
      throw new Error(`Finding already exists: ${finding.findingId}`);
    }
    this.findings.set(finding.findingId, { ...finding, status: "open" });
  }

  fixFinding(findingId: string): Finding {
    const finding = this.requireFinding(findingId);
    if (!["open", "reopened"].includes(finding.status)) {
      throw new Error(
        `Finding ${findingId} cannot be fixed from ${finding.status}`,
      );
    }
    const fixed = { ...finding, status: "fixed" as const };
    this.findings.set(findingId, fixed);
    this.fixedAfterVerificationSequence.set(
      findingId,
      this.verificationSequence,
    );
    return fixed;
  }

  verifyFinding(findingId: string, verifierWorkerId: string): Finding {
    const finding = this.requireFinding(findingId);
    if (finding.status !== "fixed") {
      throw new Error(`Finding ${findingId} requires a fix before re-review`);
    }
    if (
      ![...this.verifications.values()]
        .filter((verification) => verification.taskId === finding.taskId)
        .some(
          (verification) =>
            verification.method === "independent_review" &&
            verification.outcome === "passed" &&
            verification.independent &&
            verification.verifierWorkerId === verifierWorkerId &&
            verification.verifierWorkerId !== finding.authorWorkerId &&
            verification.sequence >
              (this.fixedAfterVerificationSequence.get(findingId) ?? 0),
        )
    ) {
      throw new Error(
        `Finding ${findingId} requires a passed independent review by ${verifierWorkerId}`,
      );
    }
    const verified = { ...finding, status: "verified" as const };
    this.findings.set(findingId, verified);
    return verified;
  }

  reopenFinding(findingId: string): Finding {
    const finding = this.requireFinding(findingId);
    const reopened = { ...finding, status: "reopened" as const };
    this.findings.set(findingId, reopened);
    return reopened;
  }

  dismissFinding(findingId: string): Finding {
    const finding = this.requireFinding(findingId);
    const dismissed = { ...finding, status: "dismissed" as const };
    this.findings.set(findingId, dismissed);
    return dismissed;
  }

  recordVerification(record: VerificationRecord): void {
    if (record.method === "independent_review" && !record.independent) {
      throw new Error("Required review must be independent");
    }
    this.verifications.set(record.verificationId, {
      ...record,
      sequence: ++this.verificationSequence,
    });
  }

  listFindings(taskId?: string): readonly Finding[] {
    return [...this.findings.values()].filter(
      (finding) => taskId === undefined || finding.taskId === taskId,
    );
  }

  listVerifications(taskId?: string): readonly VerificationRecord[] {
    return [...this.verifications.values()].filter(
      (verification) => taskId === undefined || verification.taskId === taskId,
    );
  }

  canComplete(taskId: string): boolean {
    return this.completionBlockers(taskId).length === 0;
  }

  assertCanComplete(taskId: string): void {
    const blockers = this.completionBlockers(taskId);
    if (blockers.length > 0) {
      throw new Error(
        `Task ${taskId} verification incomplete: ${blockers.join(", ")}`,
      );
    }
  }

  private completionBlockers(taskId: string): string[] {
    const blockers: string[] = [];
    if (
      this.policy.independentReviewRequired &&
      !this.listVerifications(taskId).some(
        (verification) =>
          verification.method === "independent_review" &&
          verification.outcome === "passed" &&
          verification.independent,
      )
    ) {
      blockers.push("independent_review");
    }
    if (
      this.policy.executableCheckRequired &&
      !this.listVerifications(taskId).some(
        (verification) =>
          verification.method === "executable_check" &&
          verification.outcome === "passed",
      )
    ) {
      blockers.push("executable_check");
    }
    if (
      this.policy.humanApprovalRequired &&
      !this.listVerifications(taskId).some(
        (verification) =>
          verification.method === "human_approval" &&
          verification.outcome === "passed",
      )
    ) {
      blockers.push("human_approval");
    }
    if (
      this.listFindings(taskId).some((finding) =>
        isBlockingFinding(finding, this.policy),
      )
    ) {
      blockers.push("blocking_finding");
    }
    return blockers;
  }

  private requireFinding(findingId: string): Finding {
    const finding = this.findings.get(findingId);
    if (finding === undefined) throw new Error(`Unknown finding: ${findingId}`);
    return finding;
  }
}
