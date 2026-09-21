import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import {
  AGENT_PROTOCOL_NAME,
  AGENT_PROTOCOL_VERSION,
  type AgentProtocolMessage,
  type DesiredWorker,
  type AssignmentResultPayload,
} from "@conclave/agent-protocol";
import { ConclaveAgentHost } from "../src/agent.js";
import type { CloudTransport } from "../src/cloud-client.js";

describe("Web / Cloud AI Worker Plugin E2E (Cloud -> Agent -> Web AI Plugin -> Relay -> Result -> Cloud)", () => {
  let tmpDir: string;
  const messagesSentToCloud: AgentProtocolMessage[] = [];

  const webWorkerConfig: DesiredWorker = {
    id: "w-chatgpt-web-1",
    workerId: "w-chatgpt-web-1",
    workspaceId: "ws-web-test",
    agentId: "agent-web-host-1",
    pluginId: "conclave.web-ai",
    pluginVersionPolicy: "1.0.0",
    name: "ChatGPT Web Architect",
    roles: ["architect", "reviewer"],
    capabilities: ["web_chat", "interactive_relay"],
    config: {
      targetPlatform: "chatgpt_web",
      relayUrl: "https://cloud.conclave.local/api/v2/connector",
      pollIntervalMs: 50,
      timeoutMs: 10000,
    },
    secretRefs: ["CONCLAVE_CONNECTOR_TOKEN"],
    billingMode: "free",
    independenceKey: "indep-web-pool-1",
    concurrencyLimit: 2,
    sessionPolicy: "stateless",
    enabled: true,
  };

  const mockTransport: CloudTransport = {
    async enrollAgent(_cloudUrl, token) {
      return {
        agentId: "agent-web-host-1",
        workspaceId: "ws-web-test",
        authToken: `tok_${token}`,
      };
    },

    async postMessage(message) {
      messagesSentToCloud.push(message);

      if (message.type === "agent.hello") {
        return {
          protocol: AGENT_PROTOCOL_NAME,
          protocolVersion: AGENT_PROTOCOL_VERSION,
          messageId: "msg-ack-hello",
          correlationId: message.messageId,
          timestamp: new Date().toISOString(),
          type: "agent.hello.ack",
          payload: {
            sessionId: "sess-web-test",
            heartbeatIntervalMs: 10000,
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
            desiredPlugins: [
              {
                pluginId: "conclave.web-ai",
                version: "1.0.0",
                packageR2Key: "plugins/conclave-web-ai-1.0.0.tar.gz",
                packageDigest: "sha256-mock-digest",
                signature: "sig-mock",
                permissions: ["network:outbound"],
              },
            ],
            desiredWorkers: [webWorkerConfig],
            activeAssignmentIds: [],
          },
        };
      }

      return {
        protocol: AGENT_PROTOCOL_NAME,
        protocolVersion: AGENT_PROTOCOL_VERSION,
        messageId: `ack-${message.messageId}`,
        correlationId: message.messageId,
        timestamp: new Date().toISOString(),
        type: "agent.heartbeat.ack",
        payload: { acknowledged: true, serverTime: new Date().toISOString() },
      };
    },
  };

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "conclave-web-ai-test-"));
    messagesSentToCloud.length = 0;

    // Create installed plugin bundle in agent storage
    const pluginInstallDir = path.join(
      tmpDir,
      "plugins",
      "conclave.web-ai",
      "1.0.0",
    );
    fs.mkdirSync(pluginInstallDir, { recursive: true });

    const fixturePath = path.resolve(
      __dirname,
      "../../../packages/plugin-sdk/fixtures/web-ai/index.mjs",
    );
    fs.copyFileSync(fixturePath, path.join(pluginInstallDir, "index.mjs"));

    fs.writeFileSync(
      path.join(pluginInstallDir, "manifest.json"),
      JSON.stringify({
        pluginId: "conclave.web-ai",
        version: "1.0.0",
        displayName: "Web AI Plugin",
        description: "Web AI Relay Plugin",
        publisher: "conclave",
        channel: "stable",
        protocolVersion: "2.0",
        minimumAgentVersion: "0.2.0",
        supportedOS: ["macos", "linux", "windows"],
        supportedArchitecture: ["arm64", "x64"],
        roles: ["architect", "reviewer"],
        capabilities: ["web_chat", "interactive_relay"],
        permissions: ["network:outbound"],
        entrypoint: "index.mjs",
        billingModes: ["free"],
        digest: "sha256-mock-digest",
      }),
      "utf8",
    );
  });

  afterEach(() => {
    try {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    } catch {
      // Ignore
    }
  });

  it("proves Cloud -> Agent -> Web AI Plugin -> Cloud Connector Relay execution loop", async () => {
    const host = new ConclaveAgentHost({
      config: {
        homeDir: tmpDir,
        workspaceId: "ws-web-test",
        agentId: "agent-web-host-1",
        maxConcurrentWorkers: 4,
        heartbeatIntervalMs: 5000,
      },
      transport: mockTransport,
    });

    await host.start();
    expect(host.isOnline).toBe(true);

    // Verify worker registered on agent
    const worker = host.workerManager.getWorker("w-chatgpt-web-1");
    expect(worker).toBeDefined();
    expect(worker?.name).toBe("ChatGPT Web Architect");

    // Cloud dispatches assignment to the Web AI worker
    const now = new Date().toISOString();
    const assignmentStartMessage: AgentProtocolMessage = {
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: "msg-web-asg-1",
      correlationId: "corr-101",
      timestamp: now,
      type: "assignment.start",
      workspaceId: "ws-web-test",
      agentId: "agent-web-host-1",
      workerId: "w-chatgpt-web-1",
      runId: "run-web-1",
      taskId: "task-web-arch",
      attemptId: "att-web-1",
      assignmentId: "asg-web-101",
      idempotencyKey: "idem-web-101",
      payload: {
        pluginId: "conclave.web-ai",
        resolvedPluginVersion: "1.0.0",
        role: "architect",
        objective: "Design distributed web consensus mechanism",
        input: { targetQps: 5000 },
        contextArtifactIds: ["art-system-spec"],
        timeoutMs: 15000,
      },
    };

    // Deliver assignment from Cloud to Agent
    const ack = await host.handleIncomingMessage(assignmentStartMessage);
    expect((ack?.payload as { accepted: boolean }).accepted).toBe(true);

    const finished = await host.workerManager.waitForIdle(10000);
    expect(finished).toBe(true);

    // Wait for worker process execution and result transmission back to Cloud
    const resultMessage = messagesSentToCloud.find(
      (m): m is Extract<AgentProtocolMessage, { type: "assignment.result" }> =>
        m.type === "assignment.result" && m.assignmentId === "asg-web-101",
    );

    expect(resultMessage).toBeDefined();
    expect(resultMessage?.type).toBe("assignment.result");
    expect(resultMessage?.workerId).toBe("w-chatgpt-web-1");

    const resultPayload = resultMessage?.payload as AssignmentResultPayload;
    expect(resultPayload.status).toBe("completed");
    expect(resultPayload.summary).toContain("chatgpt_web");
    expect(resultPayload.output).toBeDefined();
    expect(resultPayload.output?.platform).toBe("chatgpt_web");
    expect(resultPayload.evidence).toBeDefined();
    expect(resultPayload.evidence?.metrics?.targetPlatform).toBe("chatgpt_web");

    await host.stop();
  });
});
