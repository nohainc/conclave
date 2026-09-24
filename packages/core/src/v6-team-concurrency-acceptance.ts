import { DomainInvariantError } from "./entities.js";

export interface TeamConcurrencyDiscussion {
  readonly workstreamId: string;
  readonly authorUserId: string;
}

export interface TeamConcurrencyExecution {
  readonly requestId: string;
  readonly workstreamId: string;
  readonly requesterUserId: string;
  readonly workspaceId: string;
  readonly checkoutPath: string;
  readonly startedAtMs: number;
  readonly finishedAtMs: number;
  readonly outcome: "completed" | "failed";
  readonly accountId: string;
  readonly accountOwnerUserId: string;
  readonly sponsorUserId: string;
}

export interface TeamConcurrencyAcceptance {
  readonly projectMemberIds: readonly string[];
  readonly removedMemberIds: readonly string[];
  readonly configuredExecutionMemberIds: readonly string[];
  readonly viewerUserId: string;
  readonly discussions: readonly TeamConcurrencyDiscussion[];
  readonly executions: readonly TeamConcurrencyExecution[];
  readonly rejectedExecutionRequesterIds: readonly string[];
}

function fail(message: string): never {
  throw new DomainInvariantError(message);
}

function pathsOverlap(left: string, right: string): boolean {
  const normalize = (path: string) => path.replaceAll("\\", "/").replace(/\/+$/, "");
  const a = normalize(left);
  const b = normalize(right);
  return a === b || a.startsWith(`${b}/`) || b.startsWith(`${a}/`);
}

/**
 * Verifies the observable guarantees of the three-contributor concurrency
 * acceptance scenario. Runtime and D1 adapters feed this contract their
 * immutable assignment/run observations.
 */
export function validateV6TeamConcurrencyAcceptance(
  acceptance: TeamConcurrencyAcceptance,
): void {
  const members = new Set(acceptance.projectMemberIds);
  for (const discussion of acceptance.discussions) {
    if (!members.has(discussion.authorUserId)) {
      fail("removed Project members cannot Discuss");
    }
  }

  const configured = new Set(acceptance.configuredExecutionMemberIds);
  for (const execution of acceptance.executions) {
    if (!members.has(execution.requesterUserId) ||
        acceptance.removedMemberIds.includes(execution.requesterUserId)) {
      fail("removed Project members cannot create new Work Requests");
    }
    if (!configured.has(execution.requesterUserId)) {
      fail("execution must be limited to configured Workstream members");
    }
    if (execution.accountOwnerUserId !== execution.sponsorUserId) {
      fail("Account usage must preserve sponsor attribution");
    }
    if (execution.finishedAtMs < execution.startedAtMs) {
      fail("execution finish precedes start");
    }
  }

  if (acceptance.rejectedExecutionRequesterIds.includes(acceptance.viewerUserId) === false) {
    fail("viewer execution must be rejected");
  }

  for (let i = 0; i < acceptance.executions.length; i += 1) {
    const current = acceptance.executions[i]!;
    for (let j = i + 1; j < acceptance.executions.length; j += 1) {
      const other = acceptance.executions[j]!;
      if (current.workstreamId !== other.workstreamId && pathsOverlap(current.checkoutPath, other.checkoutPath)) {
        fail("Workstream checkout paths overlap");
      }
      const sameWorkstream = current.workstreamId === other.workstreamId;
      const overlapsInTime = current.startedAtMs < other.finishedAtMs &&
        other.startedAtMs < current.finishedAtMs;
      if (sameWorkstream && overlapsInTime) {
        fail("stateful Work Requests in one Workstream must serialize");
      }
    }
  }

  const failedWorkstreams = new Set(
    acceptance.executions
      .filter((execution) => execution.outcome === "failed")
      .map((execution) => execution.workstreamId),
  );
  for (const execution of acceptance.executions) {
    if (
      execution.outcome === "failed" &&
      [...failedWorkstreams].some((workstreamId) => workstreamId !== execution.workstreamId)
    ) {
      fail("failed Workstream execution must be isolated");
    }
  }
  const hasConcurrentIndependentWork = acceptance.executions.some((current, index) =>
    acceptance.executions.slice(index + 1).some((other) =>
      current.workstreamId !== other.workstreamId &&
      current.startedAtMs < other.finishedAtMs &&
      other.startedAtMs < current.finishedAtMs,
    ),
  );
  if (!hasConcurrentIndependentWork) {
    fail("different Workstreams must run concurrently");
  }
}
