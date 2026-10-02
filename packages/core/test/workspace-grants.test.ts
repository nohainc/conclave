import { describe, expect, it } from "vitest";
import { resolveEffectivePermissions } from "../src/index.js";

describe("Workspace grant permission intersection", () => {
  it("keeps only permissions allowed by every authorization boundary", () => {
    expect(
      resolveEffectivePermissions({
        projectMemberPermissions: ["repository:read", "repository:write"],
        workspaceGrantPermissions: ["repository:read", "repository:write"],
        workerManifestPermissions: ["repository:read"],
        workspaceLocalPermissions: ["repository:read", "shell:execute"],
        projectPolicyPermissions: ["repository:read", "repository:write"],
      }),
    ).toEqual(["repository:read"]);
  });
});
