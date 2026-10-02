import { describe, expect, it } from "vitest";
import {
  grantExecutionPermissions,
  grantStringArray,
} from "../src/routes/workspace-access.js";

describe("Workspace Grant execution permissions", () => {
  it("accepts the canonical permission IDs", () => {
    expect(
      grantExecutionPermissions(["repository:read", "shell:execute"]),
    ).toBe('["repository:read","shell:execute"]');
  });

  it("rejects aliases and unknown permission IDs at the write boundary", () => {
    expect(() => grantExecutionPermissions(["workspace:read"])).toThrow(
      /invalid or duplicate/,
    );
    expect(() => grantExecutionPermissions(["system:admin"])).toThrow(
      /invalid or duplicate/,
    );
    expect(() =>
      grantExecutionPermissions(["repository:read", "repository:read"]),
    ).toThrow(/invalid or duplicate/);
  });

  it("rejects unsupported or duplicate capability and Worker ID values", () => {
    expect(() =>
      grantStringArray(
        ["authorized_context_read", "run_shell"],
        "allowedWorkerCapabilities",
      ),
    ).toThrow(/invalid or duplicate/);
    expect(() =>
      grantStringArray(["worker-a", "worker-a"], "allowedWorkerIds"),
    ).toThrow(/invalid or duplicate/);
    expect(grantStringArray(["text"], "allowedWorkerCapabilities")).toBe(
      '["text"]',
    );
  });
});
