import { describe, expect, it } from "vitest";
import {
  type Workspace,
  type Project,
  type Chat,
  type ChatMessage,
  type ConclaveAgent,
  type WorkerPlugin,
  type WorkerPluginChannel,
  type Worker,
  type WorkerAssignment,
  type WorkerAssignmentResult,
  type AgentRelease,
  DomainInvariantError,
  validateWorkspace,
  validateProject,
  validateChat,
  validateChatMessage,
  validateAgent,
  validateAgentRelease,
  validateWorkerPlugin,
  validateWorkerPluginVersion,
  validateWorker,
  validateAssignment,
  validateAssignmentResult,
} from "../src/index.js";

describe("Architecture v2 Core Domain Entities and Invariants", () => {
  const sampleWorkspace: Workspace = {
    id: "ws-primary",
    name: "Engineering Team",
    slug: "engineering",
    createdAt: "2026-09-21T10:00:00Z",
    updatedAt: "2026-09-21T10:00:00Z",
  };

  const sampleAgent: ConclaveAgent = {
    id: "agent-macbook-pro",
    workspaceId: "ws-primary",
    name: "Dev MacBook Pro",
    hostname: "macbook-pro.local",
    status: "online",
    version: "0.2.0",
    capabilities: {
      os: "macos",
      arch: "arm64",
      version: "0.2.0",
      supportedRuntimes: ["node22", "xcode", "git"],
      maxConcurrentWorkers: 4,
    },
    enrolledAt: "2026-09-21T10:05:00Z",
    lastHeartbeatAt: "2026-09-21T12:00:00Z",
    revokedAt: null,
  };

  const samplePlugin: WorkerPlugin = {
    id: "codex",
    displayName: "Codex Worker Plugin",
    description: "Executes code changes using Codex CLI agent",
    publisher: "conclave-official",
    supportedRoles: ["implementer", "researcher"],
    supportedCapabilities: ["code_editing", "git_workspace"],
    status: "active",
  };

  const sampleWorker: Worker = {
    id: "worker-codex-main",
    workspaceId: "ws-primary",
    agentId: "agent-macbook-pro",
    pluginId: "codex",
    pluginVersionPolicy: "latest",
    name: "Codex Main Implementer",
    roles: ["implementer"],
    capabilities: ["code_editing"],
    config: { timeoutSec: 300 },
    secretRefs: ["local:codex_session_token"],
    billingMode: "subscription",
    costMetadata: { currency: "USD", estimatedCostMicrosPerAttempt: 5000 },
    independenceKey: "openai-codex-v1",
    concurrencyLimit: 2,
    sessionPolicy: "isolated_workspace",
    enabled: true,
    availability: "available",
    status: "available",
    createdAt: "2026-09-21T10:10:00Z",
    updatedAt: "2026-09-21T10:10:00Z",
  };

  const sampleAssignment: WorkerAssignment = {
    id: "asgn-001",
    workspaceId: "ws-primary",
    runId: "run-100",
    taskId: "task-01",
    attemptId: "att-001-a",
    agentId: "agent-macbook-pro",
    workerId: "worker-codex-main",
    pluginId: "codex",
    resolvedPluginVersion: "1.0.0",
    status: "dispatched",
    input: { objective: "Implement login view" },
    idempotencyKey: "idemp-run100-task01-att01",
    timeoutMs: 60000,
    createdAt: "2026-09-21T12:01:00Z",
    updatedAt: "2026-09-21T12:01:00Z",
  };

  const sampleResult: WorkerAssignmentResult = {
    assignmentId: "asgn-001",
    workspaceId: "ws-primary",
    runId: "run-100",
    taskId: "task-01",
    attemptId: "att-001-a",
    agentId: "agent-macbook-pro",
    workerId: "worker-codex-main",
    status: "completed",
    output: { summary: "Login view implemented successfully" },
    findings: [],
    artifactIds: ["art-diff-01"],
    completedAt: "2026-09-21T12:02:30Z",
  };

  describe("Workspace invariants", () => {
    it("validates a valid workspace", () => {
      expect(() => validateWorkspace(sampleWorkspace)).not.toThrow();
    });

    it("rejects empty workspace fields", () => {
      expect(() => validateWorkspace({ ...sampleWorkspace, id: "" })).toThrow(
        DomainInvariantError,
      );
      expect(() =>
        validateWorkspace({ ...sampleWorkspace, name: " " }),
      ).toThrow(DomainInvariantError);
    });
  });

  describe("Agent invariants", () => {
    it("validates a valid agent", () => {
      expect(() => validateAgent(sampleAgent)).not.toThrow();
    });

    it("rejects invalid agent capabilities or missing workspace", () => {
      expect(() => validateAgent({ ...sampleAgent, workspaceId: "" })).toThrow(
        DomainInvariantError,
      );
      expect(() =>
        validateAgent({
          ...sampleAgent,
          capabilities: {
            ...sampleAgent.capabilities,
            maxConcurrentWorkers: 0,
          },
        }),
      ).toThrow(DomainInvariantError);
    });
  });

  describe("Worker invariants", () => {
    it("validates a valid Worker within Agent and Plugin context", () => {
      expect(() =>
        validateWorker(sampleWorker, {
          agent: sampleAgent,
          plugin: samplePlugin,
        }),
      ).not.toThrow();
    });

    it("enforces: Worker belongs to one Workspace (rejects cross-workspace reference)", () => {
      const otherWorkspaceAgent: ConclaveAgent = {
        ...sampleAgent,
        id: "agent-other",
        workspaceId: "ws-secondary",
      };

      expect(() =>
        validateWorker(
          { ...sampleWorker, agentId: "agent-other" },
          { agent: otherWorkspaceAgent, plugin: samplePlugin },
        ),
      ).toThrow(/Cross-workspace violation/);
    });

    it("enforces: Worker hosted by one Agent (rejects agent id mismatch)", () => {
      expect(() =>
        validateWorker(
          { ...sampleWorker, agentId: "agent-wrong" },
          { agent: sampleAgent, plugin: samplePlugin },
        ),
      ).toThrow(/does not match host Agent id/);
    });

    it("enforces: Worker references one Plugin (rejects plugin id mismatch)", () => {
      expect(() =>
        validateWorker(
          { ...sampleWorker, pluginId: "anthropic" },
          { agent: sampleAgent, plugin: samplePlugin },
        ),
      ).toThrow(/does not match Plugin id/);
    });

    it("rejects Worker assigned to revoked Agent", () => {
      const revokedAgent: ConclaveAgent = {
        ...sampleAgent,
        status: "revoked",
        revokedAt: "2026-09-21T11:00:00Z",
      };

      expect(() =>
        validateWorker(sampleWorker, {
          agent: revokedAgent,
          plugin: samplePlugin,
        }),
      ).toThrow(/revoked Agent/);
    });

    it("rejects Worker referencing revoked Plugin", () => {
      const revokedPlugin: WorkerPlugin = {
        ...samplePlugin,
        status: "revoked",
      };

      expect(() =>
        validateWorker(sampleWorker, {
          agent: sampleAgent,
          plugin: revokedPlugin,
        }),
      ).toThrow(/revoked Plugin/);
    });

    it("validates sessionPolicy and availability invariants", () => {
      expect(() =>
        validateWorker({
          ...sampleWorker,
          sessionPolicy: "invalid_policy" as unknown as Worker["sessionPolicy"],
        }),
      ).toThrow(/Invalid Worker sessionPolicy/);

      expect(() =>
        validateWorker({
          ...sampleWorker,
          availability: "invalid_avail" as unknown as Worker["availability"],
        }),
      ).toThrow(/Invalid Worker availability/);
    });
  });

  describe("Assignment invariants", () => {
    it("validates a valid WorkerAssignment", () => {
      expect(() =>
        validateAssignment(sampleAssignment, {
          worker: sampleWorker,
          attemptId: "att-001-a",
        }),
      ).not.toThrow();
    });

    it("enforces: Assignment targets exactly one Worker (rejects worker mismatch)", () => {
      expect(() =>
        validateAssignment(
          { ...sampleAssignment, workerId: "worker-other" },
          { worker: sampleWorker },
        ),
      ).toThrow(/does not match Worker id/);
    });

    it("enforces: Assignment corresponds to exactly one Attempt", () => {
      expect(() =>
        validateAssignment(
          { ...sampleAssignment, attemptId: "att-002" },
          { worker: sampleWorker, attemptId: "att-001-a" },
        ),
      ).toThrow(/does not match target attempt/);
    });

    it("enforces: Cross-workspace assignment is rejected", () => {
      expect(() =>
        validateAssignment(
          { ...sampleAssignment, workspaceId: "ws-foreign" },
          { worker: sampleWorker },
        ),
      ).toThrow(/Cross-workspace violation/);
    });

    it("enforces: Assignment cannot target a disabled Worker", () => {
      const disabledWorker: Worker = {
        ...sampleWorker,
        enabled: false,
        status: "disabled",
      };

      expect(() =>
        validateAssignment(sampleAssignment, { worker: disabledWorker }),
      ).toThrow(/disabled Worker/);
    });
  });

  describe("Assignment result and Agent execution boundary", () => {
    it("validates a matching WorkerAssignmentResult", () => {
      expect(() =>
        validateAssignmentResult(sampleResult, sampleAssignment),
      ).not.toThrow();
    });

    it("rejects result matching wrong assignment ID", () => {
      expect(() =>
        validateAssignmentResult(
          { ...sampleResult, assignmentId: "asgn-999" },
          sampleAssignment,
        ),
      ).toThrow(/does not match Assignment id/);
    });

    it("rejects result with mismatched attempt ID", () => {
      expect(() =>
        validateAssignmentResult(
          { ...sampleResult, attemptId: "att-mismatch" },
          sampleAssignment,
        ),
      ).toThrow(/does not match Assignment target/);
    });
  });

  describe("Projects and Chats hierarchy invariants", () => {
    const sampleProject: Project = {
      id: "proj-1",
      workspaceId: "ws-primary",
      name: "Conclave Core",
      description: "Core runtime and studio",
      repositoryId: "repo-conclave",
      settings: {},
      createdAt: "2026-09-21T10:00:00Z",
      updatedAt: "2026-09-21T10:00:00Z",
    };

    const sampleChat: Chat = {
      id: "chat-1",
      projectId: "proj-1",
      workspaceId: "ws-primary",
      createdByUserId: "user-1",
      title: "Architecture Planning",
      status: "active",
      createdAt: "2026-09-21T10:05:00Z",
      updatedAt: "2026-09-21T10:05:00Z",
    };

    const sampleMessage: ChatMessage = {
      id: "msg-1",
      chatId: "chat-1",
      senderType: "user",
      senderId: "user-1",
      content: "Research architecture and prepare proposal",
      kind: "user",
      metadata: {},
      createdAt: "2026-09-21T10:05:00Z",
    };

    it("validates a valid Project", () => {
      expect(() =>
        validateProject(sampleProject, sampleWorkspace),
      ).not.toThrow();
    });

    it("rejects cross-workspace Project association", () => {
      expect(() =>
        validateProject(sampleProject, {
          ...sampleWorkspace,
          id: "ws-different",
        }),
      ).toThrow(/Cross-workspace violation/);
    });

    it("validates a valid Chat", () => {
      expect(() =>
        validateChat(sampleChat, {
          project: sampleProject,
          workspace: sampleWorkspace,
        }),
      ).not.toThrow();
    });

    it("rejects Chat with mismatched project workspace", () => {
      expect(() =>
        validateChat(sampleChat, {
          project: { ...sampleProject, workspaceId: "ws-other" },
        }),
      ).toThrow(/Cross-workspace violation/);
    });

    it("validates a valid ChatMessage", () => {
      expect(() =>
        validateChatMessage(sampleMessage, sampleChat),
      ).not.toThrow();
    });

    it("rejects ChatMessage with mismatched chatId", () => {
      expect(() =>
        validateChatMessage(
          { ...sampleMessage, chatId: "chat-different" },
          sampleChat,
        ),
      ).toThrow(/does not match target Chat/);
    });

    it("validates valid WorkerPlugin and WorkerPluginVersion with release channel", () => {
      expect(() => validateWorkerPlugin(samplePlugin)).not.toThrow();

      const version = {
        id: "ver-1",
        pluginId: "codex",
        version: "1.0.0",
        channel: "stable" as const,
        protocolVersion: "2.0",
        minAgentVersion: "0.2.0",
        supportedOs: ["macos" as const],
        supportedArch: ["arm64" as const],
        packageDigest: "sha256:abc",
        packageR2Key: "plugins/codex/1.0.0/pkg.tgz",
        signature: "sig-test",
        permissions: ["fs:read"],
        billingModes: ["subscription" as const],
        isRevoked: false,
        createdAt: "2026-09-21T10:00:00Z",
      };

      expect(() =>
        validateWorkerPluginVersion(version, samplePlugin),
      ).not.toThrow();
    });

    it("rejects WorkerPluginVersion with invalid release channel or mismatched parent plugin", () => {
      const version = {
        id: "ver-1",
        pluginId: "codex",
        version: "1.0.0",
        channel: "invalid_chan" as unknown as WorkerPluginChannel,
        protocolVersion: "2.0",
        minAgentVersion: "0.2.0",
        supportedOs: ["macos" as const],
        supportedArch: ["arm64" as const],
        packageDigest: "sha256:abc",
        packageR2Key: "plugins/codex/1.0.0/pkg.tgz",
        signature: "sig-test",
        permissions: [],
        billingModes: ["free" as const],
        isRevoked: false,
        createdAt: "2026-09-21T10:00:00Z",
      };

      expect(() => validateWorkerPluginVersion(version, samplePlugin)).toThrow(
        /Invalid WorkerPluginVersion channel/,
      );

      const mismatchedVersion = {
        ...version,
        channel: "beta" as const,
        pluginId: "other-plugin",
      };
      expect(() =>
        validateWorkerPluginVersion(mismatchedVersion, samplePlugin),
      ).toThrow(/does not match parent plugin/);
    });

    it("validates valid AgentRelease and rejects invalid ones", () => {
      const release: AgentRelease = {
        version: "1.3.0",
        channel: "stable",
        minSupportedAgentVersion: "1.0.0",
        supportedOS: ["macos", "linux"],
        supportedArch: ["arm64", "x64"],
        packageDigest: "sha256:abc12345",
        packageR2Key: "agent/releases/1.3.0/agent-1.3.0.tar.gz",
        signature: "sig_pkg_12345",
        releaseNotes: "v1.3.0 release",
        isRevoked: false,
        createdAt: "2026-09-21T12:00:00Z",
      };

      expect(() => validateAgentRelease(release)).not.toThrow();

      expect(() =>
        validateAgentRelease({
          ...release,
          channel: "unknown" as unknown as AgentRelease["channel"],
        }),
      ).toThrow(/Invalid AgentRelease channel/);

      expect(() =>
        validateAgentRelease({
          ...release,
          supportedOS: [],
        }),
      ).toThrow(/AgentRelease must support at least one OS/);

      expect(() =>
        validateAgentRelease({
          ...release,
          signature: "",
        }),
      ).toThrow(/AgentRelease signature is required/);
    });
  });
});
