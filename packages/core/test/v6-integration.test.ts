import { describe, expect, it } from "vitest";
import {
  applyIntegrationAction,
  canManageWorkstreamIntegration,
  type WorkstreamIntegration,
} from "../src/index.js";

const initial: WorkstreamIntegration = {
  id: "integration-1",
  projectId: "project-1",
  workstreamId: "workstream-1",
  requestedByUserId: "owner-1",
  provider: "github",
  status: "draft",
  branchName: null,
  baseRevision: "base-1",
  headRevision: null,
  pullRequestNumber: null,
  pullRequestUrl: null,
  patchArtifactId: null,
  error: null,
  createdAt: "2026-01-01T00:00:00.000Z",
  updatedAt: "2026-01-01T00:00:00.000Z",
};

describe("v6 Workstream integrations", () => {
  it("records publish, PR metadata, merge, and completion", () => {
    const published = applyIntegrationAction(initial, {
      type: "publish_branch",
      branchName: "conclave/workstream-1",
      headRevision: "head-1",
    });
    const pr = applyIntegrationAction(published, {
      type: "create_pr",
      title: "Implement Workstream result",
      body: "Details",
      url: "https://github.com/o/r/pull/7",
      number: 7,
      baseRevision: "base-1",
    });
    expect(pr.pullRequestNumber).toBe(7);
    const ready = applyIntegrationAction(pr, {
      type: "mark_merge_ready",
      baseRevision: "base-1",
    });
    const merged = applyIntegrationAction(ready, {
      type: "merge",
      mergeRevision: "merge-1",
      baseRevision: "base-1",
    });
    expect(applyIntegrationAction(merged, { type: "complete" }).status).toBe(
      "completed",
    );
  });

  it("handles already-published branches, moved bases, and conflicts", () => {
    const published = applyIntegrationAction(initial, {
      type: "publish_branch",
      branchName: "conclave/workstream-1",
      headRevision: "head-1",
    });
    expect(
      applyIntegrationAction(published, {
        type: "publish_branch",
        branchName: "conclave/workstream-1",
        headRevision: "head-2",
      }).headRevision,
    ).toBe("head-2");
    const conflict = applyIntegrationAction(published, {
      type: "create_pr",
      title: "Result",
      body: "",
      url: "https://github.com/o/r/pull/8",
      number: 8,
      baseRevision: "base-2",
    });
    expect(conflict.status).toBe("conflict");
    expect(
      applyIntegrationAction(conflict, {
        type: "export_patch",
        artifactId: "artifact-1",
      }).status,
    ).toBe("patch_exported");
  });

  it("requires Project owner integration authorization", () => {
    expect(
      canManageWorkstreamIntegration({
        projectRole: "owner",
        allowedByWorkstreamPolicy: true,
      }),
    ).toBe(true);
    expect(
      canManageWorkstreamIntegration({
        projectRole: "collaborator",
        allowedByWorkstreamPolicy: true,
      }),
    ).toBe(false);
    expect(
      canManageWorkstreamIntegration({
        projectRole: "owner",
        allowedByWorkstreamPolicy: false,
      }),
    ).toBe(false);
  });
});
