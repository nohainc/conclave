import { describe, expect, it } from "vitest";
import { validateV6TeamConcurrencyAcceptance } from "../src/v6-team-concurrency-acceptance.js";

const base = {
  projectMemberIds: ["owner", "alice", "bob", "carol", "viewer"],
  removedMemberIds: [],
  configuredExecutionMemberIds: ["owner", "alice", "bob", "carol"],
  viewerUserId: "viewer",
  discussions: [
    { workstreamId: "a", authorUserId: "owner" },
    { workstreamId: "a", authorUserId: "alice" },
    { workstreamId: "b", authorUserId: "bob" },
    { workstreamId: "c", authorUserId: "carol" },
  ],
  executions: [
    {
      requestId: "a1", workstreamId: "a", requesterUserId: "alice", workspaceId: "mac-1",
      checkoutPath: "/managed/a", startedAtMs: 0, finishedAtMs: 10, outcome: "failed" as const,
      accountId: "acct-owner", accountOwnerUserId: "owner", sponsorUserId: "owner",
    },
    {
      requestId: "a2", workstreamId: "a", requesterUserId: "alice", workspaceId: "mac-1",
      checkoutPath: "/managed/a", startedAtMs: 10, finishedAtMs: 20, outcome: "completed" as const,
      accountId: "acct-alice", accountOwnerUserId: "alice", sponsorUserId: "alice",
    },
    {
      requestId: "b1", workstreamId: "b", requesterUserId: "bob", workspaceId: "mac-1",
      checkoutPath: "/managed/b", startedAtMs: 1, finishedAtMs: 9, outcome: "completed" as const,
      accountId: "acct-bob", accountOwnerUserId: "bob", sponsorUserId: "bob",
    },
    {
      requestId: "c1", workstreamId: "c", requesterUserId: "carol", workspaceId: "mac-2",
      checkoutPath: "/managed/c", startedAtMs: 1, finishedAtMs: 9, outcome: "completed" as const,
      accountId: "acct-carol", accountOwnerUserId: "carol", sponsorUserId: "carol",
    },
  ],
  rejectedExecutionRequesterIds: ["viewer"],
} as const;

describe("V6 team concurrency acceptance", () => {
  it("proves the shared-Workspace and independent-Workspace topology", () => {
    expect(() => validateV6TeamConcurrencyAcceptance(base)).not.toThrow();
  });

  it("rejects overlapping stateful requests in one Workstream", () => {
    expect(() => validateV6TeamConcurrencyAcceptance({
      ...base,
      executions: base.executions.map((execution) =>
        execution.requestId === "a2"
          ? { ...execution, startedAtMs: 5 }
          : execution,
      ),
    })).toThrow("must serialize");
  });

  it("rejects checkout path reuse and missing viewer denial", () => {
    expect(() => validateV6TeamConcurrencyAcceptance({
      ...base,
      executions: base.executions.map((execution) =>
        execution.requestId === "b1"
          ? { ...execution, checkoutPath: "/managed/a/child" }
          : execution,
      ),
    })).toThrow("checkout paths overlap");
    expect(() => validateV6TeamConcurrencyAcceptance({
      ...base,
      rejectedExecutionRequesterIds: [],
    })).toThrow("viewer execution");
  });

  it("blocks new work after Project removal", () => {
    expect(() => validateV6TeamConcurrencyAcceptance({
      ...base,
      removedMemberIds: ["bob"],
      executions: base.executions.map((execution) =>
        execution.requestId === "b1"
          ? { ...execution, requesterUserId: "bob" }
          : execution,
      ),
    })).toThrow("removed Project members");
  });
});
