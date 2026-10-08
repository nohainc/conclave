import { describe, expect, it } from "vitest";
import {
  canTransitionWorkspaceSpaceGrantStatus,
  resolveExecutionPermissions,
  validateWorkspaceConcurrencyPolicy,
  validateWorkspaceGrantCapabilities,
  validateWorkspaceGrantPermissions,
  validateWorkspaceGrantWorkerIds,
  validateWorkspaceNetworkPolicy,
} from "../src/index.js";

describe("Workspace Grant execution permissions", () => {
  it("intersects the Space role with the Workspace Grant", () => {
    expect(
      resolveExecutionPermissions(
        ["repository:read", "repository:write", "shell:execute"],
        ["repository:read", "shell:execute"],
      ),
    ).toEqual(["repository:read", "shell:execute"]);
  });

  it("validates the canonical grant permission, capability, and Worker ID sets", () => {
    expect(
      validateWorkspaceGrantPermissions(["repository:read", "network:use"]),
    ).toBe(true);
    expect(
      validateWorkspaceGrantPermissions(["repository:read", "repository:read"]),
    ).toBe(false);
    expect(validateWorkspaceGrantPermissions(["workspace:read"])).toBe(false);
    expect(
      validateWorkspaceGrantCapabilities(["authorized_context_read", "text"]),
    ).toBe(true);
    expect(validateWorkspaceGrantCapabilities(["run_shell"])).toBe(false);
    expect(validateWorkspaceGrantWorkerIds(["worker:chatgpt-1"])).toBe(true);
    expect(validateWorkspaceGrantWorkerIds(["../other-workspace"])).toBe(false);
    expect(validateWorkspaceGrantWorkerIds(["worker-1", "worker-1"])).toBe(
      false,
    );
  });

  it("requires exact, bounded network and concurrency policies", () => {
    expect(
      validateWorkspaceNetworkPolicy({ mode: "deny_all", allowedHosts: [] }),
    ).toBe(true);
    expect(
      validateWorkspaceNetworkPolicy({
        mode: "allowlist",
        allowedHosts: ["api.example.com"],
      }),
    ).toBe(true);
    expect(
      validateWorkspaceNetworkPolicy({
        mode: "allowlist",
        allowedHosts: ["https://api.example.com/path"],
      }),
    ).toBe(false);
    expect(
      validateWorkspaceNetworkPolicy({
        mode: "deny_all",
        allowedHosts: ["api.example.com"],
      }),
    ).toBe(false);
    expect(
      validateWorkspaceNetworkPolicy({
        mode: "allowlist",
        allowedHosts: ["api.example.com", "api.example.com"],
      }),
    ).toBe(false);
    expect(
      validateWorkspaceConcurrencyPolicy({ maxConcurrentAssignments: 4 }),
    ).toBe(true);
    expect(
      validateWorkspaceConcurrencyPolicy({ maxConcurrentAssignments: 0 }),
    ).toBe(false);
    expect(
      validateWorkspaceConcurrencyPolicy({
        maxConcurrentAssignments: 4,
        unlimited: true,
      }),
    ).toBe(false);
  });

  it("allows only reversible active/suspended status transitions", () => {
    expect(canTransitionWorkspaceSpaceGrantStatus("active", "suspended")).toBe(
      true,
    );
    expect(canTransitionWorkspaceSpaceGrantStatus("suspended", "active")).toBe(
      true,
    );
    expect(canTransitionWorkspaceSpaceGrantStatus("active", "revoked")).toBe(
      true,
    );
    expect(canTransitionWorkspaceSpaceGrantStatus("revoked", "active")).toBe(
      false,
    );
    expect(canTransitionWorkspaceSpaceGrantStatus("expired", "revoked")).toBe(
      false,
    );
  });
});
