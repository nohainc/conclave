import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import {
  AGENT_PROTOCOL_NAME,
  AGENT_PROTOCOL_VERSION,
  type AgentProtocolMessage,
  type DesiredWorker,
} from "@conclave/agent-protocol";
import { ConclaveAgentHost } from "../src/agent.js";
import type { CloudTransport } from "../src/cloud-client.js";

describe("ConclaveAgentHost", () => {
  let tmpDir: string;
  const messagesSentToCloud: AgentProtocolMessage[] = [];

  const mockWorker: DesiredWorker = {
    workerId: "w-codex-1",
    pluginId: "plugin-codex",
    pluginVersionPolicy: "1.0.0",
    name: "Codex Worker",
    roles: ["coder"],
    capabilities: ["code_write"],
    config: {},
    secretRefs: [],
    billingMode: "local_compute",
    independenceKey: "indep-codex-1",
    concurrencyLimit: 2,
    enabled: true,
  };

  const mockTransport: CloudTransport = {
    async enrollAgent(_cloudUrl, token) {
      return {
        agentId: "agent-enrolled-1",
        workspaceId: "ws-enrolled-1",
        authToken: `tok_${token}`,
      };
    },

    async postMessage(message) {
      messagesSentToCloud.push(message);

      if (message.type === "agent.hello") {
        return {
          protocol: AGENT_PROTOCOL_NAME,
          protocolVersion: AGENT_PROTOCOL_VERSION,
          messageId: "msg-ack-1",
          correlationId: message.messageId,
          timestamp: new Date().toISOString(),
          type: "agent.hello.ack",
          payload: {
            sessionId: "sess-test-123",
            heartbeatIntervalMs: 5000,
            serverTime: new Date().toISOString(),
            serverVersion: "2.0.0",
          },
        };
      }

      if (message.type === "agent.heartbeat") {
        return {
          protocol: AGENT_PROTOCOL_NAME,
          protocolVersion: AGENT_PROTOCOL_VERSION,
          messageId: "msg-hb-ack",
          correlationId: message.messageId,
          timestamp: new Date().toISOString(),
          type: "agent.heartbeat.ack",
          payload: {
            acknowledged: true,
            serverTime: new Date().toISOString(),
          },
        };
      }

      if (message.type === "agent.sync.request") {
        return {
          protocol: AGENT_PROTOCOL_NAME,
          protocolVersion: AGENT_PROTOCOL_VERSION,
          messageId: "msg-sync-ack",
          correlationId: message.messageId,
          timestamp: new Date().toISOString(),
          type: "agent.sync.response",
          payload: {
            desiredPlugins: [],
            desiredWorkers: [mockWorker],
            activeAssignmentIds: [],
          },
        };
      }

      return undefined;
    },
  };

  beforeEach(() => {
    messagesSentToCloud.length = 0;
    tmpDir = path.join(os.tmpdir(), `conclave-agent-host-test-${Date.now()}`);
    fs.mkdirSync(tmpDir, { recursive: true });
  });

  afterEach(() => {
    try {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    } catch {
      // ignore
    }
  });

  it("starts up, completes handshake, synchronizes workers, and stops cleanly", async () => {
    const host = new ConclaveAgentHost({
      config: {
        homeDir: tmpDir,
        workspaceId: "ws-test",
        agentId: "agent-test-1",
        heartbeatIntervalMs: 1000,
      },
      transport: mockTransport,
    });

    expect(host.isOnline).toBe(false);

    await host.start();

    expect(host.isOnline).toBe(true);
    expect(host.currentSessionId).toBe("sess-test-123");
    expect(host.workerManager.getWorker("w-codex-1")).toBeDefined();

    // Verify messages sent
    const messageTypes = messagesSentToCloud.map((m) => m.type);
    expect(messageTypes).toContain("agent.hello");
    expect(messageTypes).toContain("agent.sync.request");

    await host.stop();
    expect(host.isOnline).toBe(false);
  });

  it("handles assignment execution message from Cloud and returns ack", async () => {
    const host = new ConclaveAgentHost({
      config: {
        homeDir: tmpDir,
        workspaceId: "ws-test",
        agentId: "agent-test-1",
      },
      transport: mockTransport,
    });

    await host.start();

    const startMessage: AgentProtocolMessage = {
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: "msg-start-1",
      timestamp: new Date().toISOString(),
      workspaceId: "ws-test",
      agentId: "agent-test-1",
      workerId: "w-codex-1",
      runId: "run-100",
      taskId: "task-200",
      attemptId: "att-300",
      assignmentId: "asg-400",
      idempotencyKey: "idem-500",
      type: "assignment.start",
      payload: {
        objective: "Execute automated unit test",
        role: "coder",
        pluginId: "plugin-codex",
        resolvedPluginVersion: "1.0.0",
        input: {},
        contextArtifactIds: [],
        timeoutMs: 5000,
      },
    };

    const reply = await host.handleIncomingMessage(startMessage);
    expect(reply).toBeDefined();
    expect(reply?.type).toBe("assignment.ack");
    if (reply && reply.type === "assignment.ack") {
      expect(reply.payload.accepted).toBe(true);
    }

    // Wait slightly for async execution and cloud reporting
    await new Promise((resolve) => setTimeout(resolve, 100));

    const assignmentResult = messagesSentToCloud.find(
      (m) => m.type === "assignment.result",
    );
    expect(assignmentResult).toBeDefined();

    await host.stop();
  });
});
