import { describe, expect, it } from "vitest";
import {
  type Host,
  type HostWorkspaceBinding,
  type HostRelease,
  type V4Worker,
  type HostWorkerInstallation,
  type CredentialProfile,
  type CredentialGrant,
  type V4WorkerAssignment,
  type V4WorkerAssignmentResult,
  DomainInvariantError,
  validateHost,
  validateHostWorkspaceBinding,
  validateHostRelease,
  validateV4Worker,
  validateHostWorkerInstallation,
  validateCredentialProfile,
  validateCredentialGrant,
  validateV4Assignment,
  validateV4AssignmentResult,
} from "../src/index.js";

describe("Architecture v4 Core Domain Entities and Invariants", () => {
  // ── Sample data ─────────────────────────────────────────────────────────

  const sampleHost: Host = {
    id: "host-macbook-pro",
    name: "Dev MacBook Pro",
    hostname: "macbook-pro.local",
    status: "online",
    version: "0.1.0",
    capabilities: {
      os: "macos",
      arch: "arm64",
      version: "0.1.0",
      supportedRuntimes: ["node22", "xcode", "git"],
      maxConcurrentWorkers: 4,
    },
    enrolledAt: "2026-09-21T10:05:00Z",
    lastHeartbeatAt: "2026-09-21T12:00:00Z",
    revokedAt: null,
  };

  const sampleWorker: V4Worker = {
    id: "codex",
    displayName: "Codex Worker",
    description: "Executes code changes using Codex CLI agent",
    publisher: "conclave-official",
    supportedRoles: ["implementer", "researcher"],
    supportedCapabilities: ["code_editing", "git_workspace"],
    status: "active",
  };

  const sampleCredentialProfile: CredentialProfile = {
    id: "cred-vitalii-codex",
    ownerType: "user",
    ownerId: "user-vitalii",
    workspaceId: "ws-primary",
    workerId: "codex",
    displayName: "Vitalii's Codex subscription",
    authType: "oauth",
    visibility: "private",
    createdAt: "2026-09-21T10:10:00Z",
    updatedAt: "2026-09-21T10:10:00Z",
  };

  const sampleAssignment: V4WorkerAssignment = {
    id: "asgn-v4-001",
    workspaceId: "ws-primary",
    runId: "run-100",
    taskId: "task-01",
    attemptId: "att-001-a",
    hostId: "host-macbook-pro",
    workerId: "codex",
    credentialProfileId: "cred-vitalii-codex",
    resolvedWorkerVersion: "1.0.0",
    model: "codex-1",
    assignmentConfig: { timeoutSec: 300 },
    status: "dispatched",
    input: { objective: "Implement login view" },
    idempotencyKey: "idemp-run100-task01-att01",
    timeoutMs: 60000,
    createdAt: "2026-09-21T12:01:00Z",
    updatedAt: "2026-09-21T12:01:00Z",
  };

  const sampleResult: V4WorkerAssignmentResult = {
    assignmentId: "asgn-v4-001",
    workspaceId: "ws-primary",
    runId: "run-100",
    taskId: "task-01",
    attemptId: "att-001-a",
    hostId: "host-macbook-pro",
    workerId: "codex",
    status: "completed",
    output: { summary: "Login view implemented successfully" },
    findings: [],
    artifactIds: ["art-diff-01"],
    completedAt: "2026-09-21T12:02:30Z",
  };

  // ── Host validation ─────────────────────────────────────────────────────

  describe("Host invariants", () => {
    it("validates a valid host", () => {
      expect(() => validateHost(sampleHost)).not.toThrow();
    });

    it("rejects missing Host id", () => {
      expect(() => validateHost({ ...sampleHost, id: "" })).toThrow(
        DomainInvariantError,
      );
    });

    it("rejects missing Host name", () => {
      expect(() => validateHost({ ...sampleHost, name: "  " })).toThrow(
        DomainInvariantError,
      );
    });

    it("rejects missing Host hostname", () => {
      expect(() => validateHost({ ...sampleHost, hostname: "" })).toThrow(
        DomainInvariantError,
      );
    });

    it("rejects invalid Host status", () => {
      expect(() =>
        validateHost({
          ...sampleHost,
          status: "invalid" as Host["status"],
        }),
      ).toThrow(/Invalid Host status/);
    });

    it("rejects maxConcurrentWorkers less than 1", () => {
      expect(() =>
        validateHost({
          ...sampleHost,
          capabilities: {
            ...sampleHost.capabilities,
            maxConcurrentWorkers: 0,
          },
        }),
      ).toThrow(/maxConcurrentWorkers must be at least 1/);
    });

    it("Host has no workspaceId field — machine identity is workspace-independent", () => {
      // TypeScript enforces this at compile time. This test documents the design
      // decision: a Host is NOT workspace-scoped unlike the v3 ConclaveAgent.
      const hostKeys = Object.keys(sampleHost);
      expect(hostKeys).not.toContain("workspaceId");
    });
  });

  // ── Multi-Workspace Host binding ────────────────────────────────────────

  describe("HostWorkspaceBinding invariants", () => {
    const binding1: HostWorkspaceBinding = {
      id: "bind-1",
      hostId: "host-macbook-pro",
      workspaceId: "ws-primary",
      status: "active",
      createdAt: "2026-09-21T10:05:00Z",
      updatedAt: "2026-09-21T10:05:00Z",
    };

    const binding2: HostWorkspaceBinding = {
      id: "bind-2",
      hostId: "host-macbook-pro",
      workspaceId: "ws-secondary",
      status: "active",
      createdAt: "2026-09-21T10:06:00Z",
      updatedAt: "2026-09-21T10:06:00Z",
    };

    it("one Host can bind to multiple Workspaces", () => {
      expect(() => validateHostWorkspaceBinding(binding1)).not.toThrow();
      expect(() => validateHostWorkspaceBinding(binding2)).not.toThrow();
      expect(binding1.hostId).toBe(binding2.hostId);
      expect(binding1.workspaceId).not.toBe(binding2.workspaceId);
    });

    it("rejects missing hostId or workspaceId", () => {
      expect(() =>
        validateHostWorkspaceBinding({ ...binding1, hostId: "" }),
      ).toThrow(DomainInvariantError);
      expect(() =>
        validateHostWorkspaceBinding({ ...binding1, workspaceId: "" }),
      ).toThrow(DomainInvariantError);
    });

    it("cross-checks Host id when context is provided", () => {
      expect(() =>
        validateHostWorkspaceBinding(binding1, { host: sampleHost }),
      ).not.toThrow();

      expect(() =>
        validateHostWorkspaceBinding(
          { ...binding1, hostId: "host-wrong" },
          { host: sampleHost },
        ),
      ).toThrow(/does not match Host id/);
    });
  });

  // ── HostRelease ─────────────────────────────────────────────────────────

  describe("HostRelease invariants", () => {
    const release: HostRelease = {
      version: "1.0.0",
      channel: "stable",
      supportedOS: ["macos", "linux"],
      supportedArch: ["arm64", "x64"],
      packageDigest: "sha256:abc123",
      packageR2Key: "host/releases/1.0.0/pkg.tgz",
      signature: "sig-test",
      isRevoked: false,
      createdAt: "2026-09-21T10:00:00Z",
    };

    it("validates a valid HostRelease", () => {
      expect(() => validateHostRelease(release)).not.toThrow();
    });

    it("rejects invalid channel", () => {
      expect(() =>
        validateHostRelease({
          ...release,
          channel: "nightly" as HostRelease["channel"],
        }),
      ).toThrow(/Invalid HostRelease channel/);
    });

    it("rejects missing packageDigest", () => {
      expect(() =>
        validateHostRelease({ ...release, packageDigest: "" }),
      ).toThrow(DomainInvariantError);
    });

    it("rejects empty supportedOS", () => {
      expect(() =>
        validateHostRelease({ ...release, supportedOS: [] }),
      ).toThrow(/at least one OS/);
    });
  });

  // ── V4Worker validation ─────────────────────────────────────────────────

  describe("V4Worker invariants", () => {
    it("validates a valid V4Worker", () => {
      expect(() => validateV4Worker(sampleWorker)).not.toThrow();
    });

    it("rejects missing publisher", () => {
      expect(() =>
        validateV4Worker({ ...sampleWorker, publisher: "" }),
      ).toThrow(DomainInvariantError);
    });

    it("rejects invalid status", () => {
      expect(() =>
        validateV4Worker({
          ...sampleWorker,
          status: "invalid" as V4Worker["status"],
        }),
      ).toThrow(/Invalid V4Worker status/);
    });

    it("accepts revoked status", () => {
      expect(() =>
        validateV4Worker({ ...sampleWorker, status: "revoked" }),
      ).not.toThrow();
    });
  });

  // ── HostWorkerInstallation ──────────────────────────────────────────────

  describe("HostWorkerInstallation invariants", () => {
    const install: HostWorkerInstallation = {
      id: "inst-1",
      hostId: "host-macbook-pro",
      workerId: "codex",
      workerVersionId: "ver-codex-1.0.0",
      resolvedVersion: "1.0.0",
      status: "installed",
      installedAt: "2026-09-21T10:10:00Z",
      updatedAt: "2026-09-21T10:10:00Z",
    };

    it("validates a valid installation", () => {
      expect(() => validateHostWorkerInstallation(install)).not.toThrow();
    });

    it("rejects missing workerId", () => {
      expect(() =>
        validateHostWorkerInstallation({ ...install, workerId: "" }),
      ).toThrow(DomainInvariantError);
    });

    it("rejects missing hostId", () => {
      expect(() =>
        validateHostWorkerInstallation({ ...install, hostId: "" }),
      ).toThrow(DomainInvariantError);
    });

    it("rejects invalid status", () => {
      expect(() =>
        validateHostWorkerInstallation({
          ...install,
          status: "broken" as HostWorkerInstallation["status"],
        }),
      ).toThrow(/Invalid HostWorkerInstallation status/);
    });
  });

  // ── CredentialProfile ───────────────────────────────────────────────────

  describe("CredentialProfile invariants", () => {
    it("validates a valid private user-owned profile", () => {
      expect(() =>
        validateCredentialProfile(sampleCredentialProfile),
      ).not.toThrow();
    });

    it("private is the default — user profiles may be private", () => {
      expect(sampleCredentialProfile.visibility).toBe("private");
      expect(() =>
        validateCredentialProfile(sampleCredentialProfile),
      ).not.toThrow();
    });

    it("rejects workspace-owned profile with private visibility", () => {
      const workspaceOwnedPrivate: CredentialProfile = {
        ...sampleCredentialProfile,
        id: "cred-ws-codex",
        ownerType: "workspace",
        ownerId: "ws-primary",
        visibility: "private",
      };
      expect(() => validateCredentialProfile(workspaceOwnedPrivate)).toThrow(
        /Workspace-owned CredentialProfile must have workspace visibility/,
      );
    });

    it("accepts workspace-owned profile with workspace visibility", () => {
      const workspaceProfile: CredentialProfile = {
        ...sampleCredentialProfile,
        id: "cred-ws-codex",
        ownerType: "workspace",
        ownerId: "ws-primary",
        visibility: "workspace",
      };
      expect(() => validateCredentialProfile(workspaceProfile)).not.toThrow();
    });

    it("rejects missing required fields", () => {
      expect(() =>
        validateCredentialProfile({ ...sampleCredentialProfile, id: "" }),
      ).toThrow(DomainInvariantError);
      expect(() =>
        validateCredentialProfile({
          ...sampleCredentialProfile,
          workerId: "",
        }),
      ).toThrow(DomainInvariantError);
      expect(() =>
        validateCredentialProfile({
          ...sampleCredentialProfile,
          displayName: "",
        }),
      ).toThrow(DomainInvariantError);
    });

    it("rejects invalid ownerType", () => {
      expect(() =>
        validateCredentialProfile({
          ...sampleCredentialProfile,
          ownerType: "team" as CredentialProfile["ownerType"],
        }),
      ).toThrow(/Invalid CredentialProfile ownerType/);
    });

    it("rejects invalid visibility", () => {
      expect(() =>
        validateCredentialProfile({
          ...sampleCredentialProfile,
          visibility: "public" as CredentialProfile["visibility"],
        }),
      ).toThrow(/Invalid CredentialProfile visibility/);
    });
  });

  // ── CredentialGrant ─────────────────────────────────────────────────────

  describe("CredentialGrant invariants", () => {
    const sharedProfile: CredentialProfile = {
      ...sampleCredentialProfile,
      visibility: "workspace",
    };

    const validGrant: CredentialGrant = {
      id: "grant-1",
      credentialProfileId: "cred-vitalii-codex",
      granteeType: "user",
      granteeId: "user-bob",
      grantedBy: "user-vitalii",
      createdAt: "2026-09-21T10:15:00Z",
    };

    it("validates a valid grant on a workspace-visible profile", () => {
      expect(() =>
        validateCredentialGrant(validGrant, { profile: sharedProfile }),
      ).not.toThrow();
    });

    it("rejects grant on a private profile", () => {
      expect(() =>
        validateCredentialGrant(validGrant, {
          profile: sampleCredentialProfile,
        }),
      ).toThrow(/Cannot create CredentialGrant on a private CredentialProfile/);
    });

    it("rejects self-grant", () => {
      const selfGrant: CredentialGrant = {
        ...validGrant,
        granteeType: "user",
        granteeId: "user-vitalii", // same as owner
      };
      expect(() =>
        validateCredentialGrant(selfGrant, { profile: sharedProfile }),
      ).toThrow(/self-grant/);
    });

    it("rejects missing required fields", () => {
      expect(() => validateCredentialGrant({ ...validGrant, id: "" })).toThrow(
        DomainInvariantError,
      );
      expect(() =>
        validateCredentialGrant({
          ...validGrant,
          credentialProfileId: "",
        }),
      ).toThrow(DomainInvariantError);
      expect(() =>
        validateCredentialGrant({ ...validGrant, granteeId: "" }),
      ).toThrow(DomainInvariantError);
    });

    it("rejects invalid granteeType", () => {
      expect(() =>
        validateCredentialGrant({
          ...validGrant,
          granteeType: "team" as CredentialGrant["granteeType"],
        }),
      ).toThrow(/Invalid CredentialGrant granteeType/);
    });
  });

  // ── V4WorkerAssignment ──────────────────────────────────────────────────

  describe("V4WorkerAssignment invariants", () => {
    it("validates a valid v4 assignment", () => {
      expect(() => validateV4Assignment(sampleAssignment)).not.toThrow();
    });

    it("requires hostId (Host is required)", () => {
      expect(() =>
        validateV4Assignment({ ...sampleAssignment, hostId: "" }),
      ).toThrow(/hostId.*Host is required/);
    });

    it("requires workerId (Worker is required)", () => {
      expect(() =>
        validateV4Assignment({ ...sampleAssignment, workerId: "" }),
      ).toThrow(/workerId.*Worker is required/);
    });

    it("requires credentialProfileId (Credential Profile is required)", () => {
      expect(() =>
        validateV4Assignment({
          ...sampleAssignment,
          credentialProfileId: "",
        }),
      ).toThrow(/credentialProfileId.*Credential Profile is required/);
    });

    it("validates attempt context match", () => {
      expect(() =>
        validateV4Assignment(sampleAssignment, { attemptId: "att-001-a" }),
      ).not.toThrow();

      expect(() =>
        validateV4Assignment(sampleAssignment, { attemptId: "att-wrong" }),
      ).toThrow(/does not match target attempt/);
    });

    it("assignment snapshot fields are readonly (TypeScript compile-time check)", () => {
      // This is a compile-time guarantee. If someone tries to assign to
      // readonly properties, TypeScript will fail compilation.
      // This test documents the design decision.
      const assignment = { ...sampleAssignment };
      expect(assignment.hostId).toBe("host-macbook-pro");
      expect(assignment.workerId).toBe("codex");
      expect(assignment.credentialProfileId).toBe("cred-vitalii-codex");
      expect(assignment.resolvedWorkerVersion).toBe("1.0.0");
      expect(assignment.model).toBe("codex-1");
    });
  });

  // ── V4WorkerAssignmentResult ────────────────────────────────────────────

  describe("V4WorkerAssignmentResult invariants", () => {
    it("validates a matching result", () => {
      expect(() =>
        validateV4AssignmentResult(sampleResult, sampleAssignment),
      ).not.toThrow();
    });

    it("rejects mismatched assignmentId", () => {
      expect(() =>
        validateV4AssignmentResult(
          { ...sampleResult, assignmentId: "asgn-999" },
          sampleAssignment,
        ),
      ).toThrow(/does not match V4WorkerAssignment id/);
    });

    it("rejects mismatched hostId", () => {
      expect(() =>
        validateV4AssignmentResult(
          { ...sampleResult, hostId: "host-wrong" },
          sampleAssignment,
        ),
      ).toThrow(/does not match V4WorkerAssignment hostId/);
    });

    it("rejects mismatched workerId", () => {
      expect(() =>
        validateV4AssignmentResult(
          { ...sampleResult, workerId: "wrong-worker" },
          sampleAssignment,
        ),
      ).toThrow(/does not match V4WorkerAssignment workerId/);
    });

    it("rejects mismatched run/task/attempt", () => {
      expect(() =>
        validateV4AssignmentResult(
          { ...sampleResult, attemptId: "att-mismatch" },
          sampleAssignment,
        ),
      ).toThrow(/does not match V4WorkerAssignment target/);
    });

    it("rejects missing terminal status", () => {
      expect(() =>
        validateV4AssignmentResult({
          ...sampleResult,
          status: "" as V4WorkerAssignmentResult["status"],
        }),
      ).toThrow(/terminal status is required/);
    });
  });
});
