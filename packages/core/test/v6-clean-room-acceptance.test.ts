import { describe, expect, it } from "vitest";
import {
  V6_SOLO_ACCEPTANCE_PHASES,
  validateV6SoloAcceptance,
} from "../src/v6-clean-room-acceptance.js";

describe("V6 solo clean-room acceptance contract", () => {
  const completeRun = {
    userId: "user-1",
    workspaceId: "workspace-1",
    projectId: "project-1",
    workstreamId: "workstream-1",
    workingDirectoryReady: true,
    firstCheckpointRevision: "checkpoint-sha-1",
    secondRequestBaseCheckpointRevision: "checkpoint-sha-1",
    pullRequestUrl: "https://github.test/org/repo/pull/1",
    completedPhases: V6_SOLO_ACCEPTANCE_PHASES,
  } as const;

  it("accepts the complete ordered journey", () => {
    expect(() => validateV6SoloAcceptance(completeRun)).not.toThrow();
  });

  it("rejects a second iteration that skips the checkpoint", () => {
    expect(() =>
      validateV6SoloAcceptance({
        ...completeRun,
        secondRequestBaseCheckpointRevision: "old-base",
      }),
    ).toThrow("second iteration must start from the first checkpoint");
  });

  it("rejects an incomplete empty-environment journey", () => {
    expect(() =>
      validateV6SoloAcceptance({
        ...completeRun,
        completedPhases: V6_SOLO_ACCEPTANCE_PHASES.slice(0, -1),
      }),
    ).toThrow("pull_request_created");
  });
});
