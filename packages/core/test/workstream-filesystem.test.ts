import { describe, expect, it } from "vitest";
import {
  WORKSTREAM_FILESYSTEM_INVARIANTS,
  sameWorkstreamFilesystemIdentity,
  validateWorkstreamFilesystemIdentity,
  workstreamFilesystemIdentityKey,
} from "../src/index.js";

describe("WD-0 Workstream filesystem invariants", () => {
  it("freezes the canonical ownership and identity model", () => {
    expect(WORKSTREAM_FILESYSTEM_INVARIANTS.directoryIdentity).toEqual([
      "projectId",
      "workstreamId",
    ]);
    expect(WORKSTREAM_FILESYSTEM_INVARIANTS.runtimeCardinality).toBe(
      "one_per_os_user_installation",
    );
    expect(WORKSTREAM_FILESYSTEM_INVARIANTS.workRootOwnership).toBe(
      "workspace_runtime_local",
    );
    expect(WORKSTREAM_FILESYSTEM_INVARIANTS.workerCwd).toBe("runtime_resolved");
    expect(WORKSTREAM_FILESYSTEM_INVARIANTS.repositories).toBe(
      "worker_managed",
    );
    expect(WORKSTREAM_FILESYSTEM_INVARIANTS.mutation).toBe(
      "one_per_workstream",
    );
    expect(WORKSTREAM_FILESYSTEM_INVARIANTS.parallelism).toBe(
      "different_workstreams",
    );
    expect(WORKSTREAM_FILESYSTEM_INVARIANTS.forbiddenPathComponents).toEqual(
      expect.arrayContaining([
        "projectName",
        "workstreamName",
        "userEmail",
        "userDisplayName",
        "workspaceId",
        "repositoryName",
      ]),
    );
  });

  it("uses only Project ID and Workstream ID for identity", () => {
    const identity = { projectId: "project-1", workstreamId: "stream-1" };
    expect(() => validateWorkstreamFilesystemIdentity(identity)).not.toThrow();
    expect(workstreamFilesystemIdentityKey(identity)).toBe(
      "9:project-18:stream-1",
    );
    expect(
      sameWorkstreamFilesystemIdentity(identity, {
        ...identity,
      }),
    ).toBe(true);
    expect(
      sameWorkstreamFilesystemIdentity(identity, {
        projectId: "project-1",
        workstreamId: "stream-2",
      }),
    ).toBe(false);
  });

  it("rejects missing logical IDs before any path resolution exists", () => {
    expect(() =>
      validateWorkstreamFilesystemIdentity({
        projectId: "",
        workstreamId: "s",
      }),
    ).toThrow(/projectId is required/);
    expect(() =>
      validateWorkstreamFilesystemIdentity({
        projectId: "p",
        workstreamId: " ",
      }),
    ).toThrow(/workstreamId is required/);
  });
});
