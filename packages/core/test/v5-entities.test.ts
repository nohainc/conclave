import { describe, expect, it } from "vitest";
import {
  canExecuteProjectThroughWorkspace,
  canUseProjectAccount,
  assertWorkspacePathAllowed,
  intersectPermissions,
  resolveEffectivePermission,
  resolveEffectivePermissions,
  validateExecutionWorkspace,
  validateProjectMemberships,
  type ExecutionWorkspace,
  type ProjectMembership,
  type WorkspaceProjectGrant,
} from "../src/index.js";

const workspace: ExecutionWorkspace = {
  id: "workspace-v5",
  ownerUserId: "user-owner",
  name: "Vitalii MacBook",
  status: "online",
  createdAt: "2026-09-24T10:00:00Z",
  updatedAt: "2026-09-24T10:00:00Z",
};

const membership = (
  userId: string,
  role: ProjectMembership["role"],
): ProjectMembership => ({
  id: `membership-${userId}`,
  projectId: "project-v5",
  userId,
  role,
  createdAt: "2026-09-24T10:00:00Z",
  updatedAt: "2026-09-24T10:00:00Z",
});

const grant: WorkspaceProjectGrant = {
  id: "grant-v5",
  projectId: "project-v5",
  workspaceId: "workspace-v5",
  grantedByUserId: "user-owner",
  status: "active",
  scope: "project_repository",
  repositoryMappings: [
    { repositoryId: "repo-conclave", workspacePath: "/work/conclave" },
  ],
  pathMappings: [{ projectPath: "/repo", workspacePath: "/work/conclave" }],
  allowedWorkerIds: ["worker-codex"],
  allowedWorkerCapabilities: ["repository"],
  allowedPermissions: ["repository:read", "repository:write"],
  networkPolicy: { mode: "deny_all", allowedHosts: [] },
  concurrency: { maxConcurrentAssignments: 2 },
  budget: null,
  requiresStepUp: false,
  expiresAt: "2027-01-01T00:00:00Z",
  createdAt: "2026-09-24T10:00:00Z",
  updatedAt: "2026-09-24T10:00:00Z",
};

describe("Architecture v5 canonical domain entities", () => {
  it("requires exactly one Workspace owner and exactly one Project owner", () => {
    expect(() => validateExecutionWorkspace(workspace)).not.toThrow();
    const memberships = [
      membership("user-owner", "owner"),
      membership("user-collaborator", "collaborator"),
    ];
    expect(() =>
      validateProjectMemberships("project-v5", memberships),
    ).not.toThrow();
    expect(() =>
      validateProjectMemberships("project-v5", [
        membership("user-owner", "owner"),
        membership("user-two", "owner"),
      ]),
    ).toThrow(/exactly one owner/);
  });

  it("does not treat Project membership as Workspace access", () => {
    expect(
      canExecuteProjectThroughWorkspace({
        requesterUserId: "user-collaborator",
        projectId: "project-v5",
        workspace,
        projectMemberships: [
          membership("user-owner", "owner"),
          membership("user-collaborator", "collaborator"),
        ],
      }),
    ).toBe(false);
  });

  it("requires a Workspace Grant for cross-user Project execution", () => {
    const input = {
      requesterUserId: "user-collaborator",
      projectId: "project-v5",
      workspace,
      projectMemberships: [
        membership("user-owner", "owner"),
        membership("user-collaborator", "collaborator"),
      ],
    };
    expect(canExecuteProjectThroughWorkspace(input)).toBe(false);
    expect(canExecuteProjectThroughWorkspace({ ...input, grant })).toBe(true);
    expect(
      canExecuteProjectThroughWorkspace({
        ...input,
        grant: { ...grant, status: "revoked" },
      }),
    ).toBe(false);
  });

  it("keeps AI Account grants independent from Workspace grants", () => {
    const base = {
      requesterUserId: "user-collaborator",
      projectId: "project-v5",
      accountOwnerUserId: "user-owner",
      projectMemberships: [
        membership("user-owner", "owner"),
        membership("user-collaborator", "collaborator"),
      ],
    };
    expect(canUseProjectAccount(base)).toBe(false);
    expect(
      canUseProjectAccount({
        ...base,
        grant: {
          id: "account-grant",
          projectId: "project-v5",
          accountId: "account-owner",
          grantedByUserId: "user-owner",
          granteeUserId: "user-collaborator",
          status: "active",
          expiresAt: null,
          createdAt: "2026-09-24T10:00:00Z",
        },
      }),
    ).toBe(true);
  });

  it("uses intersection semantics for effective permissions", () => {
    expect(
      intersectPermissions(
        ["repository:read", "repository:write"],
        ["repository:read", "shell:execute"],
      ),
    ).toEqual(["repository:read"]);
    expect(
      resolveEffectivePermissions({
        projectMemberPermissions: [
          "repository:read",
          "repository:write",
          "shell:execute",
        ],
        workspaceGrantPermissions: ["repository:read", "repository:write"],
        workerManifestPermissions: ["repository:read", "repository:write"],
        workspaceLocalPermissions: ["repository:read"],
        projectPolicyPermissions: ["repository:read", "repository:write"],
      }),
    ).toEqual(["repository:read"]);
  });

  it("rejects path traversal and symlink escapes", () => {
    expect(() =>
      assertWorkspacePathAllowed({
        scope: "selected_paths",
        pathMappings: grant.pathMappings,
        requestedPath: "/repo/../secrets",
      }),
    ).toThrow(/outside|escapes/);
    expect(() =>
      assertWorkspacePathAllowed({
        scope: "selected_paths",
        pathMappings: grant.pathMappings,
        requestedPath: "/repo/link",
        symlinkTargetPath: "/etc/passwd",
      }),
    ).toThrow(/Symlink target escapes/);
  });

  it("rejects undeclared Workers, revoked grants, expired grants, and viewers", () => {
    const base = {
      requesterUserId: "user-collaborator",
      projectId: "project-v5",
      workspace,
      projectMembership: membership("user-collaborator", "collaborator"),
      grant,
      workerId: "worker-codex",
      workerCapabilities: ["repository"],
      workerManifestPermissions: ["repository:read", "repository:write"],
      workspaceLocalPermissions: ["repository:read", "repository:write"],
      projectPolicyPermissions: ["repository:read", "repository:write"],
      now: "2026-10-01T00:00:00Z",
    };
    expect(() =>
      resolveEffectivePermission({ ...base, workerId: "worker-other" }),
    ).toThrow(/not allowed/);
    expect(() =>
      resolveEffectivePermission({
        ...base,
        grant: { ...grant, status: "revoked" },
      }),
    ).toThrow(/not active/);
    expect(() =>
      resolveEffectivePermission({
        ...base,
        grant: { ...grant, expiresAt: "2026-09-01T00:00:00Z" },
      }),
    ).toThrow(/expired/);
    expect(() =>
      resolveEffectivePermission({
        ...base,
        projectMembership: membership("user-collaborator", "viewer"),
      }),
    ).toThrow(/viewers/);
  });

  it("requires step-up for full Workspace grants", () => {
    const input = {
      requesterUserId: "user-collaborator",
      projectId: "project-v5",
      workspace,
      projectMembership: membership("user-collaborator", "collaborator"),
      grant: { ...grant, scope: "full_workspace" as const },
      workerId: "worker-codex",
      workerCapabilities: ["repository"],
      workerManifestPermissions: ["repository:read", "repository:write"],
      workspaceLocalPermissions: ["repository:read"],
      projectPolicyPermissions: ["repository:read", "repository:write"],
      now: "2026-10-01T00:00:00Z",
    };
    expect(() => resolveEffectivePermission(input)).toThrow(/step-up/);
    expect(() =>
      resolveEffectivePermission({ ...input, stepUpVerified: true }),
    ).not.toThrow();
  });

  it("snapshots grant narrowing without mutating the historical permission object", () => {
    const snapshot = resolveEffectivePermission({
      requesterUserId: "user-collaborator",
      projectId: "project-v5",
      workspace,
      projectMembership: membership("user-collaborator", "collaborator"),
      grant,
      workerId: "worker-codex",
      workerCapabilities: ["repository"],
      workerManifestPermissions: ["repository:read", "repository:write"],
      workspaceLocalPermissions: ["repository:read", "repository:write"],
      projectPolicyPermissions: ["repository:read", "repository:write"],
      now: "2026-10-01T00:00:00Z",
    });
    const narrowedGrant = {
      ...grant,
      allowedPermissions: ["repository:read"],
    };
    expect(narrowedGrant.allowedPermissions).toEqual(["repository:read"]);
    expect(snapshot.permissions).toEqual([
      "repository:read",
      "repository:write",
    ]);
    expect(snapshot.grantId).toBe(grant.id);
    expect(snapshot.pathMappings).toEqual(grant.pathMappings);
  });
});
