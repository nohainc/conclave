import { describe, expect, it } from "vitest";
import {
  HOST_PROTOCOL_NAME,
  HOST_PROTOCOL_VERSION,
  parseHostMessage,
  parseWorkerRpcMessage,
  isCompatibleHostProtocolVersion,
  UnsupportedHostProtocolVersionError,
  MalformedProtocolMessageError,
  type AssignmentSnapshot,
} from "../src/index.js";

describe("Conclave Host & Worker Protocol v4", () => {
  const hostBaseEnvelope = {
    protocol: HOST_PROTOCOL_NAME,
    protocolVersion: HOST_PROTOCOL_VERSION,
    messageId: "msg-host-001",
    timestamp: "2026-09-23T10:00:00.000Z",
  };

  const sampleSnapshot: AssignmentSnapshot = {
    assignmentId: "asgn-v4-001",
    workspaceId: "ws-primary",
    projectId: "proj-web",
    runId: "run-100",
    taskId: "task-01",
    attemptId: "att-001-a",
    requestedByUserId: "user-vitalii",
    hostId: "host-macbook-pro",
    workerId: "codex",
    resolvedWorkerVersion: "1.0.0",
    credentialProfileId: "cred-vitalii-codex", // Opaque reference
    model: "codex-1",
    config: { timeoutSec: 300 },
    sessionPolicy: "isolated_workspace",
    permissions: ["fs:read", "fs:write", "process:spawn"],
    contextRefs: [{ uri: "repo://conclave/packages/core", commit: "abc123" }],
    timeoutMs: 60000,
    idempotencyKey: "idemp-run100-task01-att01",
  };

  const hostAssignmentEnvelope = {
    ...hostBaseEnvelope,
    workspaceId: "ws-primary",
    hostId: "host-macbook-pro",
    workerId: "codex",
    runId: "run-100",
    taskId: "task-01",
    attemptId: "att-001-a",
    assignmentId: "asgn-v4-001",
    idempotencyKey: "idemp-run100-task01-att01",
  };

  describe("Host Lifecycle & Presence Messages", () => {
    it("parses valid host.hello message", () => {
      const msg = {
        ...hostBaseEnvelope,
        type: "host.hello",
        payload: {
          hostId: "host-macbook-pro",
          name: "MacBook Pro Dev",
          hostname: "mbp.local",
          hostVersion: "0.1.0",
          capabilities: {
            os: "macos",
            arch: "arm64",
            version: "0.1.0",
            supportedRuntimes: ["node22", "git", "xcode"],
            maxConcurrentWorkers: 4,
          },
          enrolledWorkspaces: ["ws-primary", "ws-secondary"],
        },
      };

      const parsed = parseHostMessage(msg);
      expect(parsed.type).toBe("host.hello");
      expect(parsed.protocolVersion).toBe(HOST_PROTOCOL_VERSION);
    });

    it("parses valid host.hello.ack message", () => {
      const msg = {
        ...hostBaseEnvelope,
        type: "host.hello.ack",
        payload: {
          hostId: "host-macbook-pro",
          status: "authenticated",
          authenticatedAt: "2026-09-23T10:00:01.000Z",
          serverVersion: "4.0.0",
          sessionToken: "sess_tok_abc",
          activeWorkspaceBindings: ["ws-primary"],
        },
      };

      const parsed = parseHostMessage(msg);
      expect(parsed.type).toBe("host.hello.ack");
    });

    it("parses valid host.heartbeat and host.heartbeat.ack messages", () => {
      const hbMsg = {
        ...hostBaseEnvelope,
        type: "host.heartbeat",
        payload: {
          hostId: "host-macbook-pro",
          timestamp: "2026-09-23T10:01:00.000Z",
          metrics: {
            cpuUsagePercent: 12.5,
            memoryUsageBytes: 4294967296,
            activeWorkers: 1,
            pendingAssignments: 0,
          },
        },
      };

      const parsedHb = parseHostMessage(hbMsg);
      expect(parsedHb.type).toBe("host.heartbeat");

      const ackMsg = {
        ...hostBaseEnvelope,
        type: "host.heartbeat.ack",
        payload: {
          hostId: "host-macbook-pro",
          acknowledgedAt: "2026-09-23T10:01:01.000Z",
          serverTime: "2026-09-23T10:01:01.000Z",
          nextHeartbeatIntervalMs: 30000,
        },
      };

      const parsedAck = parseHostMessage(ackMsg);
      expect(parsedAck.type).toBe("host.heartbeat.ack");
    });

    it("parses valid host.sync.request and host.sync.result messages", () => {
      const req = {
        ...hostBaseEnvelope,
        type: "host.sync.request",
        payload: {
          hostId: "host-macbook-pro",
          syncToken: "tok-prev",
          knownAssignmentIds: ["asgn-01"],
          knownWorkerIds: ["codex"],
        },
      };
      const parsedReq = parseHostMessage(req);
      expect(parsedReq.type).toBe("host.sync.request");

      const res = {
        ...hostBaseEnvelope,
        type: "host.sync.result",
        payload: {
          hostId: "host-macbook-pro",
          syncToken: "tok-new",
          pendingAssignments: [],
          installedWorkers: ["codex@1.0.0"],
          credentialStatuses: { "cred-vitalii-codex": "ready" },
        },
      };
      const parsedRes = parseHostMessage(res);
      expect(parsedRes.type).toBe("host.sync.result");
    });

    it("parses valid host.status and host.update messages", () => {
      const statusMsg = {
        ...hostBaseEnvelope,
        type: "host.status",
        payload: {
          hostId: "host-macbook-pro",
          status: "online",
          activeAssignmentsCount: 2,
        },
      };
      expect(parseHostMessage(statusMsg).type).toBe("host.status");

      const updateMsg = {
        ...hostBaseEnvelope,
        type: "host.update",
        payload: {
          hostId: "host-macbook-pro",
          targetVersion: "0.2.0",
          packageDigest: "sha256:11223344",
          packageR2Key: "host/releases/0.2.0.tgz",
          signature: "sig_host_020",
          channel: "stable",
        },
      };
      expect(parseHostMessage(updateMsg).type).toBe("host.update");
    });
  });

  describe("Worker Management over Host Protocol", () => {
    it("parses worker.install, worker.remove, and worker.status", () => {
      const installMsg = {
        ...hostBaseEnvelope,
        type: "worker.install",
        payload: {
          hostId: "host-macbook-pro",
          workerId: "codex",
          version: "1.0.0",
          packageDigest: "sha256:abcd",
          packageR2Key: "workers/codex/1.0.0.tgz",
          signature: "sig_codex_100",
          entrypoint: "bin/codex_worker.dart",
          permissions: ["fs:read", "fs:write"],
        },
      };
      expect(parseHostMessage(installMsg).type).toBe("worker.install");

      const removeMsg = {
        ...hostBaseEnvelope,
        type: "worker.remove",
        payload: {
          hostId: "host-macbook-pro",
          workerId: "codex",
          version: "0.9.0",
          purgeData: true,
        },
      };
      expect(parseHostMessage(removeMsg).type).toBe("worker.remove");

      const statusMsg = {
        ...hostBaseEnvelope,
        type: "worker.status",
        payload: {
          hostId: "host-macbook-pro",
          workerId: "codex",
          version: "1.0.0",
          status: "ready",
        },
      };
      expect(parseHostMessage(statusMsg).type).toBe("worker.status");
    });

    it("parses credential.status message", () => {
      const credMsg = {
        ...hostBaseEnvelope,
        type: "credential.status",
        payload: {
          hostId: "host-macbook-pro",
          credentialProfileId: "cred-vitalii-codex",
          workerId: "codex",
          status: "ready",
          authMode: "oauth_browser",
          visibility: "private",
          lastCheckedAt: "2026-09-23T10:00:00.000Z",
        },
      };
      expect(parseHostMessage(credMsg).type).toBe("credential.status");
    });
  });

  describe("Assignment Snapshot & Execution Lifecycle", () => {
    it("parses assignment.start with comprehensive snapshot", () => {
      const startMsg = {
        ...hostAssignmentEnvelope,
        type: "assignment.start",
        payload: {
          snapshot: sampleSnapshot,
          input: {
            objective: "Implement login view",
          },
        },
      };

      const parsed = parseHostMessage(startMsg);
      expect(parsed.type).toBe("assignment.start");
    });

    it("secret rule: uses opaque credentialProfileId, without raw secret fields", () => {
      expect(sampleSnapshot.credentialProfileId).toBe("cred-vitalii-codex");
      expect(sampleSnapshot).not.toHaveProperty("rawApiKey");
      expect(sampleSnapshot).not.toHaveProperty("secretToken");

      const inlineSecret = {
        ...hostAssignmentEnvelope,
        type: "assignment.start",
        payload: {
          snapshot: { ...sampleSnapshot, rawApiKey: "plaintext-secret" },
          input: {},
        },
      };
      expect(() => parseHostMessage(inlineSecret)).toThrow(
        MalformedProtocolMessageError,
      );
    });

    it("supports optional fields in assignment snapshot", () => {
      const minimalSnapshot: AssignmentSnapshot = {
        assignmentId: "asgn-min",
        workspaceId: "ws-min",
        projectId: "proj-min",
        runId: "run-min",
        taskId: "task-min",
        attemptId: "att-min",
        requestedByUserId: "user-min",
        hostId: "host-min",
        workerId: "git-test",
        resolvedWorkerVersion: "1.0.0",
        credentialProfileId: "cred-none",
        config: {},
        sessionPolicy: "stateless",
        permissions: [],
        contextRefs: [],
        timeoutMs: 30000,
        idempotencyKey: "idemp-min",
      };

      const startMsg = {
        ...hostAssignmentEnvelope,
        assignmentId: "asgn-min",
        taskId: "task-min",
        attemptId: "att-min",
        runId: "run-min",
        idempotencyKey: "idemp-min",
        type: "assignment.start",
        payload: {
          snapshot: minimalSnapshot,
          input: {},
        },
      };

      const parsed = parseHostMessage(startMsg);
      expect(parsed.type).toBe("assignment.start");
    });

    it("parses assignment.ack, assignment.progress, assignment.result, assignment.error, assignment.cancel", () => {
      const ackMsg = {
        ...hostAssignmentEnvelope,
        type: "assignment.ack",
        payload: {
          assignmentId: "asgn-v4-001",
          hostId: "host-macbook-pro",
          workerId: "codex",
          status: "accepted",
          acknowledgedAt: "2026-09-23T10:02:00.000Z",
        },
      };
      expect(parseHostMessage(ackMsg).type).toBe("assignment.ack");

      const progressMsg = {
        ...hostAssignmentEnvelope,
        type: "assignment.progress",
        payload: {
          assignmentId: "asgn-v4-001",
          percentage: 50,
          message: "Compiling code changes...",
          observedAt: "2026-09-23T10:02:30.000Z",
        },
      };
      expect(parseHostMessage(progressMsg).type).toBe("assignment.progress");

      const resultMsg = {
        ...hostAssignmentEnvelope,
        type: "assignment.result",
        payload: {
          assignmentId: "asgn-v4-001",
          status: "completed",
          output: { summary: "Implemented" },
          findings: [],
          artifactIds: ["art-diff-1"],
          completedAt: "2026-09-23T10:03:00.000Z",
        },
      };
      expect(parseHostMessage(resultMsg).type).toBe("assignment.result");

      const errorMsg = {
        ...hostAssignmentEnvelope,
        type: "assignment.error",
        payload: {
          assignmentId: "asgn-v4-001",
          error: {
            code: "PROCESS_CRASHED",
            message: "Process exited with code 1",
            retryable: true,
          },
          failedAt: "2026-09-23T10:03:00.000Z",
        },
      };
      expect(parseHostMessage(errorMsg).type).toBe("assignment.error");

      const cancelMsg = {
        ...hostAssignmentEnvelope,
        type: "assignment.cancel",
        payload: {
          assignmentId: "asgn-v4-001",
          reason: "User cancelled run",
        },
      };
      expect(parseHostMessage(cancelMsg).type).toBe("assignment.cancel");

      const cancelAckMsg = {
        ...hostAssignmentEnvelope,
        type: "assignment.cancel.ack",
        payload: {
          assignmentId: "asgn-v4-001",
          cancelled: true,
        },
      };
      expect(parseHostMessage(cancelAckMsg).type).toBe("assignment.cancel.ack");
    });
  });

  describe("Host <-> Worker Protocol (JSON-RPC 2.0)", () => {
    it("parses valid worker JSON-RPC requests (initialize, health, describe, execute, cancel, shutdown)", () => {
      const initReq = {
        jsonrpc: "2.0",
        id: "req-1",
        method: "initialize",
        params: {
          workerId: "codex",
          version: "1.0.0",
          protocolVersion: "4.0",
          hostVersion: "0.1.0",
          config: { timeout: 300 },
          permissions: ["fs:read"],
        },
      };
      const parsedInit = parseWorkerRpcMessage(initReq);
      expect(parsedInit.method).toBe("initialize");

      const execReq = {
        jsonrpc: "2.0",
        id: 2,
        method: "execute",
        params: {
          assignment: sampleSnapshot,
          input: { task: "run" },
        },
      };
      const parsedExec = parseWorkerRpcMessage(execReq);
      expect(parsedExec.method).toBe("execute");

      const cancelReq = {
        jsonrpc: "2.0",
        id: "req-3",
        method: "cancel",
        params: {
          assignmentId: "asgn-v4-001",
          reason: "timeout",
        },
      };
      expect(parseWorkerRpcMessage(cancelReq).method).toBe("cancel");
    });

    it("parses valid worker notifications and streaming events", () => {
      const progressNotif = {
        jsonrpc: "2.0",
        method: "progress",
        params: {
          assignmentId: "asgn-v4-001",
          percentage: 75,
          message: "Tests running",
          timestamp: "2026-09-23T10:02:45.000Z",
        },
      };
      expect(parseWorkerRpcMessage(progressNotif).method).toBe("progress");

      for (const notification of [
        {
          method: "status",
          params: {
            assignmentId: "asgn-v4-001",
            status: "running",
            timestamp: "2026-09-23T10:02:46.000Z",
          },
        },
        {
          method: "output_delta",
          params: {
            assignmentId: "asgn-v4-001",
            delta: "partial output",
            sequence: 1,
            timestamp: "2026-09-23T10:02:47.000Z",
          },
        },
        {
          method: "tool.started",
          params: {
            assignmentId: "asgn-v4-001",
            toolCallId: "tool-call-1",
            tool: "shell",
            timestamp: "2026-09-23T10:02:48.000Z",
          },
        },
        {
          method: "tool.completed",
          params: {
            assignmentId: "asgn-v4-001",
            toolCallId: "tool-call-1",
            tool: "shell",
            success: true,
            timestamp: "2026-09-23T10:02:49.000Z",
          },
        },
      ]) {
        expect(
          parseWorkerRpcMessage({
            jsonrpc: "2.0",
            ...notification,
          }).method,
        ).toBe(notification.method);
      }

      const usageNotif = {
        jsonrpc: "2.0",
        method: "usage",
        params: {
          assignmentId: "asgn-v4-001",
          tokensUsed: 1540,
          estimatedCostMicros: 2310,
          timestamp: "2026-09-23T10:02:50.000Z",
        },
      };
      expect(parseWorkerRpcMessage(usageNotif).method).toBe("usage");

      const resultNotif = {
        jsonrpc: "2.0",
        method: "result",
        params: {
          assignmentId: "asgn-v4-001",
          status: "completed",
          output: { done: true },
          findings: [],
          artifactIds: ["art-1"],
          completedAt: "2026-09-23T10:03:00.000Z",
        },
      };
      expect(parseWorkerRpcMessage(resultNotif).method).toBe("result");
    });

    it("rejects malformed worker events and unsupported methods", () => {
      expect(() =>
        parseWorkerRpcMessage({
          jsonrpc: "1.0", // Invalid JSON-RPC
          id: "1",
          method: "initialize",
        }),
      ).toThrow(MalformedProtocolMessageError);

      expect(() =>
        parseWorkerRpcMessage({
          jsonrpc: "2.0",
          method: "output_delta",
          params: {
            assignmentId: "asgn-v4-001",
            delta: "x".repeat(8193),
            timestamp: "2026-09-23T10:02:47.000Z",
          },
        }),
      ).toThrow(MalformedProtocolMessageError);

      expect(() =>
        parseWorkerRpcMessage({
          jsonrpc: "2.0",
          id: "1",
          method: "unsupported_magic_method",
          params: {},
        }),
      ).toThrow(MalformedProtocolMessageError);

      expect(() =>
        parseWorkerRpcMessage({
          jsonrpc: "2.0",
          method: "progress",
          params: { assignmentId: "asgn-v4-001", percentage: 101 },
        }),
      ).toThrow(MalformedProtocolMessageError);
    });
  });

  describe("Version Compatibility & Protocol Invariants", () => {
    it("enforces compatible protocol version rules", () => {
      expect(isCompatibleHostProtocolVersion("4.0", "4.0")).toBe(true);
      expect(isCompatibleHostProtocolVersion("4.0", "4.1")).toBe(true);
      expect(isCompatibleHostProtocolVersion("4.1", "4.0")).toBe(false);
      expect(isCompatibleHostProtocolVersion("4.0", "5.0")).toBe(false);
      expect(isCompatibleHostProtocolVersion("4.0", "3.9")).toBe(false);
    });

    it("rejects incompatible major protocol versions in parseHostMessage", () => {
      const badVersionMsg = {
        ...hostBaseEnvelope,
        protocolVersion: "5.0",
        type: "host.status",
        payload: {
          hostId: "host-macbook-pro",
          status: "online",
        },
      };

      expect(() => parseHostMessage(badVersionMsg)).toThrow(
        UnsupportedHostProtocolVersionError,
      );
    });

    it("validates assignment idempotency key present on assignment envelope", () => {
      const missingIdempMsg = {
        ...hostAssignmentEnvelope,
        idempotencyKey: "",
        type: "assignment.start",
        payload: {
          snapshot: sampleSnapshot,
          input: {},
        },
      };

      expect(() => parseHostMessage(missingIdempMsg)).toThrow(
        MalformedProtocolMessageError,
      );
    });

    it("rejects a snapshot whose idempotency key differs from the envelope", () => {
      const mismatched = {
        ...hostAssignmentEnvelope,
        type: "assignment.start",
        payload: {
          snapshot: { ...sampleSnapshot, idempotencyKey: "different-key" },
          input: {},
        },
      };

      expect(() => parseHostMessage(mismatched)).toThrow(
        MalformedProtocolMessageError,
      );
    });
  });
});
