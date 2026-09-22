import { describe, expect, it } from "vitest";
import {
  AGENT_PROTOCOL_NAME,
  AGENT_PROTOCOL_VERSION,
  parseAgentMessage,
  serializeAgentMessage,
  isCompatibleAgentProtocolVersion,
  reconcileAssignmentJournal,
  UnsupportedProtocolVersionError,
  MalformedMessageError,
  type AgentProtocolMessage,
  type CloudAssignmentRecord,
} from "../src/index.js";

describe("Conclave Agent Protocol v2", () => {
  const baseEnvelope = {
    protocol: AGENT_PROTOCOL_NAME,
    protocolVersion: AGENT_PROTOCOL_VERSION,
    messageId: "msg-001",
    timestamp: "2026-09-21T12:00:00.000Z",
  };

  const baseAssignmentEnvelope = {
    ...baseEnvelope,
    workspaceId: "ws-test",
    agentId: "agent-01",
    workerId: "worker-codex",
    runId: "run-001",
    taskId: "task-001",
    attemptId: "att-001",
    assignmentId: "asgn-001",
    idempotencyKey: "idemp-001",
  };

  describe("Agent Lifecycle Messages", () => {
    it("parses valid agent.hello message", () => {
      const msg = {
        ...baseEnvelope,
        type: "agent.hello",
        payload: {
          agentId: "agent-01",
          workspaceId: "ws-test",
          name: "MacBook Dev",
          hostname: "mbp.local",
          agentVersion: "0.2.0",
          capabilities: {
            os: "macos",
            arch: "arm64",
            agentVersion: "0.2.0",
            supportedRuntimes: ["node22", "git"],
            maxConcurrentWorkers: 4,
          },
        },
      };

      const parsed = parseAgentMessage(msg);
      expect(parsed.type).toBe("agent.hello");
      expect(parsed.protocolVersion).toBe(AGENT_PROTOCOL_VERSION);
    });

    it("parses valid agent.heartbeat message", () => {
      const msg = {
        ...baseEnvelope,
        type: "agent.heartbeat",
        payload: {
          agentId: "agent-01",
          workspaceId: "ws-test",
          sessionId: "sess-100",
          status: "online",
          activeWorkers: 2,
          activeAssignments: 1,
        },
      };

      const parsed = parseAgentMessage(msg);
      expect(parsed.type).toBe("agent.heartbeat");
    });

    it("parses valid agent.update.available and agent.update.status messages", () => {
      const availMsg = {
        ...baseEnvelope,
        type: "agent.update.available",
        payload: {
          version: "1.3.0",
          channel: "stable",
          packageR2Key: "agent/releases/1.3.0.tar.gz",
          packageDigest: "sha256:abcd",
          signature: "sig_pkg_123",
          releaseNotes: "Critical fixes",
        },
      };

      const parsedAvail = parseAgentMessage(availMsg);
      expect(parsedAvail.type).toBe("agent.update.available");

      const statusMsg = {
        ...baseEnvelope,
        type: "agent.update.status",
        payload: {
          fromVersion: "1.2.0",
          targetVersion: "1.3.0",
          status: "draining",
        },
      };

      const parsedStatus = parseAgentMessage(statusMsg);
      expect(parsedStatus.type).toBe("agent.update.status");
    });
  });

  it("accepts compatible minor versions and rejects incompatible majors", () => {
    expect(isCompatibleAgentProtocolVersion("2.0", "2.1")).toBe(true);
    expect(isCompatibleAgentProtocolVersion("2.0", "1.9")).toBe(false);
    expect(() =>
      parseAgentMessage({
        ...baseEnvelope,
        protocolVersion: "3.0",
        type: "agent.hello",
        payload: {
          agentId: "agent-01",
          workspaceId: "ws-test",
          name: "MacBook Dev",
          hostname: "mbp.local",
          agentVersion: "0.2.0",
          capabilities: {
            os: "macos",
            arch: "arm64",
            agentVersion: "0.2.0",
            supportedRuntimes: ["dart"],
            maxConcurrentWorkers: 1,
          },
        },
      }),
    ).toThrow(UnsupportedProtocolVersionError);
  });

  describe("Plugin Management Messages", () => {
    it("parses valid plugin.install message", () => {
      const msg = {
        ...baseEnvelope,
        type: "plugin.install",
        payload: {
          pluginId: "codex",
          version: "1.2.0",
          packageR2Key: "plugins/codex-1.2.0.tgz",
          packageDigest: "sha256:abc123def456",
          signature: "sig-valid-789",
          permissions: ["fs.read", "fs.write", "process.spawn"],
        },
      };

      const parsed = parseAgentMessage(msg);
      expect(parsed.type).toBe("plugin.install");
    });
  });

  describe("Worker Management Messages", () => {
    it("parses valid worker.configure message with complete configuration", () => {
      const msg = {
        ...baseEnvelope,
        type: "worker.configure",
        payload: {
          worker: {
            id: "worker-gpt-architect",
            workerId: "worker-gpt-architect",
            workspaceId: "ws-test",
            agentId: "agent-01",
            pluginId: "openai",
            pluginVersionPolicy: "^1.4",
            name: "GPT Architect",
            roles: ["architect"],
            capabilities: ["code_design", "adr_generation"],
            config: { model: "o3-mini", temperature: 0.2 },
            secretRefs: ["OPENAI_API_KEY"],
            billingMode: "api_metered",
            costMetadata: {
              currency: "USD",
              inputMicrosPerMillionTokens: 1100,
            },
            independenceKey: "key-gpt-arch",
            concurrencyLimit: 2,
            sessionPolicy: "isolated_workspace",
            availability: "available",
            enabled: true,
          },
        },
      };

      const parsed = parseAgentMessage(msg);
      expect(parsed.type).toBe("worker.configure");
      if (parsed.type === "worker.configure") {
        expect(parsed.payload.worker.workerId).toBe("worker-gpt-architect");
        expect(parsed.payload.worker.sessionPolicy).toBe("isolated_workspace");
        expect(parsed.payload.worker.billingMode).toBe("api_metered");
      }
    });
  });

  describe("Assignment Execution Messages & Envelope Invariants", () => {
    it("parses valid assignment.start message with complete execution envelope", () => {
      const msg = {
        ...baseAssignmentEnvelope,
        type: "assignment.start",
        payload: {
          objective: "Fix bug in auth service",
          role: "implementer",
          pluginId: "codex",
          resolvedPluginVersion: "1.2.0",
          input: { path: "src/auth.ts" },
          contextArtifactIds: ["art-1", "art-2"],
          timeoutMs: 30000,
        },
      };

      const parsed = parseAgentMessage(msg);
      expect(parsed.type).toBe("assignment.start");
      if (parsed.type === "assignment.start") {
        expect(parsed.assignmentId).toBe("asgn-001");
        expect(parsed.attemptId).toBe("att-001");
        expect(parsed.workerId).toBe("worker-codex");
      }
    });

    it("parses valid assignment.result message", () => {
      const msg = {
        ...baseAssignmentEnvelope,
        type: "assignment.result",
        payload: {
          status: "completed",
          summary: "Patch applied cleanly",
          output: { changes: 1 },
          artifactIds: ["art-patch-1"],
        },
      };

      const parsed = parseAgentMessage(msg);
      expect(parsed.type).toBe("assignment.result");
    });

    it("parses valid assignment.error message", () => {
      const msg = {
        ...baseAssignmentEnvelope,
        type: "assignment.error",
        payload: {
          status: "failed",
          error: {
            code: "PROCESS_TIMEOUT",
            message: "Worker exceeded 30000ms limit",
            retryable: true,
          },
        },
      };

      const parsed = parseAgentMessage(msg);
      expect(parsed.type).toBe("assignment.error");
    });

    it("rejects assignment message missing mandatory correlation fields (e.g. attemptId)", () => {
      const rawMsg: Record<string, unknown> = {
        ...baseAssignmentEnvelope,
        type: "assignment.start",
        payload: {
          objective: "Task",
          role: "implementer",
          pluginId: "codex",
          resolvedPluginVersion: "1.0.0",
          input: {},
          contextArtifactIds: [],
          timeoutMs: 10000,
        },
      };
      delete rawMsg.attemptId;

      expect(() => parseAgentMessage(rawMsg)).toThrow(MalformedMessageError);
    });

    it("rejects assignment message missing idempotencyKey", () => {
      const rawMsg: Record<string, unknown> = {
        ...baseAssignmentEnvelope,
        type: "assignment.start",
        payload: {
          objective: "Task",
          role: "implementer",
          pluginId: "codex",
          resolvedPluginVersion: "1.0.0",
          input: {},
          contextArtifactIds: [],
          timeoutMs: 10000,
        },
      };
      delete rawMsg.idempotencyKey;

      expect(() => parseAgentMessage(rawMsg)).toThrow(MalformedMessageError);
    });
  });

  describe("Protocol Errors & Boundary Rejections", () => {
    it("rejects message with unsupported protocol version", () => {
      const msg = {
        ...baseEnvelope,
        protocolVersion: "1.0",
        type: "agent.heartbeat",
        payload: {
          agentId: "agent-01",
          workspaceId: "ws-test",
          sessionId: "sess-1",
          status: "online",
          activeWorkers: 0,
          activeAssignments: 0,
        },
      };

      expect(() => parseAgentMessage(msg)).toThrow(
        UnsupportedProtocolVersionError,
      );
    });

    it("rejects message with invalid protocol identifier", () => {
      const msg = {
        ...baseEnvelope,
        protocol: "invalid-protocol",
        type: "agent.heartbeat",
        payload: {},
      };

      expect(() => parseAgentMessage(msg)).toThrow(MalformedMessageError);
    });

    it("rejects non-object payload", () => {
      expect(() => parseAgentMessage("not a json object")).toThrow(
        MalformedMessageError,
      );
      expect(() => parseAgentMessage(null)).toThrow(MalformedMessageError);
    });

    it("serializes valid message to JSON", () => {
      const msg: AgentProtocolMessage = {
        ...baseEnvelope,
        type: "agent.heartbeat.ack",
        payload: {
          acknowledged: true,
          serverTime: "2026-09-21T12:00:00.000Z",
        },
      };

      const json = serializeAgentMessage(msg);
      expect(typeof json).toBe("string");
      expect(JSON.parse(json).type).toBe("agent.heartbeat.ack");
    });
  });

  describe("Reconnect Journal Reconciliation", () => {
    it("reconciles offline completed assignment by submitting result", () => {
      const cloudRecords: CloudAssignmentRecord[] = [
        {
          assignmentId: "asgn-01",
          attemptId: "att-01",
          idempotencyKey: "idemp-01",
          status: "running",
        },
      ];

      const agentJournal = [
        {
          assignmentId: "asgn-01",
          attemptId: "att-01",
          idempotencyKey: "idemp-01",
          status: "completed" as const,
          terminalResult: { output: "done" },
          updatedAt: "2026-09-21T12:05:00.000Z",
        },
      ];

      const actions = reconcileAssignmentJournal(cloudRecords, agentJournal);
      expect(actions).toEqual([
        {
          action: "submit_result",
          assignmentId: "asgn-01",
          terminalResult: { output: "done" },
        },
      ]);
    });

    it("cancels orphaned assignment no longer tracked by Cloud", () => {
      const cloudRecords: CloudAssignmentRecord[] = [];
      const agentJournal = [
        {
          assignmentId: "asgn-orphaned",
          attemptId: "att-02",
          idempotencyKey: "idemp-02",
          status: "running" as const,
          updatedAt: "2026-09-21T12:05:00.000Z",
        },
      ];

      const actions = reconcileAssignmentJournal(cloudRecords, agentJournal);
      expect(actions).toEqual([
        {
          action: "cancel_orphaned",
          assignmentId: "asgn-orphaned",
        },
      ]);
    });
  });
});
