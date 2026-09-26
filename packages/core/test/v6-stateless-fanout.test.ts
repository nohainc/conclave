import { describe, expect, it } from "vitest";
import {
  planStatelessFanOut,
  type StatelessFanOutRequest,
} from "../src/index.js";

const base = (): StatelessFanOutRequest => ({
  projectId: "project-1",
  workstreamId: "workstream-1",
  workRequestId: "request-1",
  primaryWorkspaceId: "workspace-primary",
  checkpointSha: "sha-1",
  currentCheckpointSha: "sha-1",
  repositorySnapshot: {
    mechanism: "repository_snapshot",
    repositoryId: "repo-1",
    revision: "sha-1",
    checkpointSha: "sha-1",
    snapshotId: "snapshot-1",
  },
  contextArtifacts: [
    { id: "artifact-b", sha256: "b", kind: "finding" },
    { id: "artifact-a", sha256: "a", kind: "brief" },
  ],
  authorizedArtifactIds: ["artifact-a", "artifact-b"],
  requiredCapabilities: ["repository:read"],
  requireIndependentProviders: true,
  candidates: [
    {
      workspaceId: "workspace-aux-2",
      workerId: "worker-2",
      accountId: "account-2",
      providerKey: "provider-b",
      capabilities: ["repository:read"],
    },
    {
      workspaceId: "workspace-primary",
      workerId: "worker-primary",
      accountId: "account-primary",
      providerKey: "provider-primary",
      capabilities: ["repository:read"],
    },
    {
      workspaceId: "workspace-aux-1",
      workerId: "worker-1",
      accountId: "account-1",
      providerKey: "provider-a",
      capabilities: ["repository:read"],
    },
  ],
});

describe("v6 stateless fan-out", () => {
  it("plans parallel auxiliary assignments from one immutable snapshot", () => {
    const plan = planStatelessFanOut(base());
    expect(plan.assignments).toHaveLength(2);
    expect(
      plan.assignments.every(
        (item) => item.workspaceId !== "workspace-primary",
      ),
    ).toBe(true);
    expect(plan.assignments.map((item) => item.providerKey)).toEqual([
      "provider-a",
      "provider-b",
    ]);
    expect(plan.snapshot.contextArtifactIds).toEqual([
      "artifact-a",
      "artifact-b",
    ]);
    expect(plan.assignments[0]?.snapshot).toEqual(plan.snapshot);
  });

  it("rejects stale checkpoints and unauthorized artifacts", () => {
    expect(() =>
      planStatelessFanOut({ ...base(), currentCheckpointSha: "sha-2" }),
    ).toThrow(/stale/);
    expect(() =>
      planStatelessFanOut({ ...base(), authorizedArtifactIds: ["artifact-a"] }),
    ).toThrow(/not authorized/);
  });

  it("requires independent providers and never accepts a Primary checkout path", () => {
    expect(() =>
      planStatelessFanOut({
        ...base(),
        candidates: base().candidates.map((candidate) => ({
          ...candidate,
          providerKey: "provider-a",
        })),
      }),
    ).toThrow(/Independent provider/);
    expect(() =>
      planStatelessFanOut({
        ...base(),
        repositorySnapshot: {
          ...base().repositorySnapshot,
          snapshotId: "primary/checkout",
        },
      }),
    ).toThrow(/opaque/);
  });
});
