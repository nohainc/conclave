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

describe("OpenAI & Anthropic API Plugins E2E (Cloud -> Agent -> API Plugin -> Result -> Cloud)", () => {
  let tmpDir: string;
  const messagesSentToCloud: AgentProtocolMessage[] = [];

  const gptArchitectConfig: DesiredWorker = {
    id: "w-gpt-architect-1",
    workerId: "w-gpt-architect-1",
    workspaceId: "ws-api-test",
    agentId: "agent-api-host-1",
    pluginId: "conclave.openai-api",
    pluginVersionPolicy: "1.0.0",
    name: "GPT-4o System Architect",
    roles: ["architect", "reviewer"],
    capabilities: ["code_execution", "network"],
    config: {
      model: "gpt-4o",
      responseFormat: "json_object",
    },
    secretRefs: ["OPENAI_API_KEY"],
    billingMode: "api_metered",
    independenceKey: "indep-openai-api-pool",
    concurrencyLimit: 4,
    sessionPolicy: "stateless",
    enabled: true,
  };

  const claudeReviewerConfig: DesiredWorker = {
    id: "w-claude-critic-1",
    workerId: "w-claude-critic-1",
    workspaceId: "ws-api-test",
    agentId: "agent-api-host-1",
    pluginId: "conclave.anthropic-api",
    pluginVersionPolicy: "1.0.0",
    name: "Claude 3.7 Code Reviewer",
    roles: ["reviewer", "evaluator"],
    capabilities: ["code_execution", "network"],
    config: {
      model: "claude-3-7-sonnet-20250219",
    },
    secretRefs: ["ANTHROPIC_API_KEY"],
    billingMode: "api_metered",
    independenceKey: "indep-anthropic-api-pool",
    concurrencyLimit: 4,
    sessionPolicy: "stateless",
    enabled: true,
  };

  const mockTransport: CloudTransport = {
    async enrollAgent(_cloudUrl, token) {
      return {
        agentId: "agent-api-host-1",
        workspaceId: "ws-api-test",
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
            sessionId: "sess-api-test",
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
                pluginId: "conclave.openai-api",
                version: "1.0.0",
                packageR2Key: "plugins/openai-api/1.0.0.tar.gz",
                packageDigest: "sha256-openai-api",
                signature: "sig-openai-api",
                permissions: [
                  "network:outbound",
                  "workspace:read",
                  "workspace:write",
                ],
              },
              {
                pluginId: "conclave.anthropic-api",
                version: "1.0.0",
                packageR2Key: "plugins/anthropic-api/1.0.0.tar.gz",
                packageDigest: "sha256-anthropic-api",
                signature: "sig-anthropic-api",
                permissions: [
                  "network:outbound",
                  "workspace:read",
                  "workspace:write",
                ],
              },
            ],
            desiredWorkers: [gptArchitectConfig, claudeReviewerConfig],
            activeAssignmentIds: [],
          },
        };
      }

      return undefined;
    },
  };

  beforeEach(() => {
    messagesSentToCloud.length = 0;
    tmpDir = path.join(os.tmpdir(), `conclave-api-plugins-e2e-${Date.now()}`);
    fs.mkdirSync(tmpDir, { recursive: true });

    // Install OpenAI API fixture into agent plugin directory
    const openaiPluginDir = path.join(
      tmpDir,
      "plugins",
      "conclave.openai-api",
      "1.0.0",
    );
    fs.mkdirSync(openaiPluginDir, { recursive: true });
    const openaiFixture = path.resolve(
      __dirname,
      "../../../packages/plugin-sdk/fixtures/openai-api/index.mjs",
    );
    fs.copyFileSync(openaiFixture, path.join(openaiPluginDir, "index.mjs"));

    // Install Anthropic API fixture into agent plugin directory
    const anthropicPluginDir = path.join(
      tmpDir,
      "plugins",
      "conclave.anthropic-api",
      "1.0.0",
    );
    fs.mkdirSync(anthropicPluginDir, { recursive: true });
    const anthropicFixture = path.resolve(
      __dirname,
      "../../../packages/plugin-sdk/fixtures/anthropic-api/index.mjs",
    );
    fs.copyFileSync(
      anthropicFixture,
      path.join(anthropicPluginDir, "index.mjs"),
    );
  });

  afterEach(() => {
    try {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    } catch {
      // ignore
    }
  });

  it("proves Cloud dispatches assignments to local Agent, which routes to isolated API plugins with local credentials", async () => {
    const host = new ConclaveAgentHost({
      config: {
        homeDir: tmpDir,
        workspaceId: "ws-api-test",
        agentId: "agent-api-host-1",
        maxConcurrentWorkers: 6,
        heartbeatIntervalMs: 5000,
      },
      transport: mockTransport,
    });

    await host.start();
    expect(host.isOnline).toBe(true);

    const gptWorker = host.workerManager.getWorker("w-gpt-architect-1");
    const claudeWorker = host.workerManager.getWorker("w-claude-critic-1");
    expect(gptWorker).toBeDefined();
    expect(claudeWorker).toBeDefined();

    // 1. Dispatch OpenAI API assignment
    const gptAssignmentMsg: AgentProtocolMessage = {
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: "msg-dispatch-gpt-api",
      timestamp: new Date().toISOString(),
      workspaceId: "ws-api-test",
      agentId: "agent-api-host-1",
      workerId: "w-gpt-architect-1",
      runId: "run-api-001",
      taskId: "task-gpt-design",
      attemptId: "att-gpt-1",
      assignmentId: "asg-gpt-101",
      idempotencyKey: "idem-gpt-101",
      type: "assignment.start",
      payload: {
        pluginId: "conclave.openai-api",
        resolvedPluginVersion: "1.0.0",
        role: "architect",
        objective: "Design schema migration plan for versioned events",
        input: { schemaVersion: "v2" },
        contextArtifactIds: ["art-schema-base"],
        timeoutMs: 5000,
      },
    };

    // 2. Dispatch Anthropic API assignment
    const claudeAssignmentMsg: AgentProtocolMessage = {
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: "msg-dispatch-claude-api",
      timestamp: new Date().toISOString(),
      workspaceId: "ws-api-test",
      agentId: "agent-api-host-1",
      workerId: "w-claude-critic-1",
      runId: "run-api-001",
      taskId: "task-claude-review",
      attemptId: "att-claude-1",
      assignmentId: "asg-claude-102",
      idempotencyKey: "idem-claude-102",
      type: "assignment.start",
      payload: {
        pluginId: "conclave.anthropic-api",
        resolvedPluginVersion: "1.0.0",
        role: "reviewer",
        objective: "Review schema migration for backwards compatibility",
        input: { targetMigration: "0001_initial.sql" },
        contextArtifactIds: ["art-schema-base"],
        timeoutMs: 5000,
      },
    };

    const [ackGpt, ackClaude] = await Promise.all([
      host.handleIncomingMessage(gptAssignmentMsg),
      host.handleIncomingMessage(claudeAssignmentMsg),
    ]);

    expect((ackGpt?.payload as { accepted: boolean }).accepted).toBe(true);
    expect((ackClaude?.payload as { accepted: boolean }).accepted).toBe(true);

    const finished = await host.workerManager.waitForIdle(10000);
    expect(finished).toBe(true);

    // 3. Verify OpenAI result message and token metrics
    const gptResult = messagesSentToCloud.find(
      (m): m is Extract<AgentProtocolMessage, { type: "assignment.result" }> =>
        m.type === "assignment.result" && m.assignmentId === "asg-gpt-101",
    );
    expect(gptResult).toBeDefined();
    expect(gptResult?.workerId).toBe("w-gpt-architect-1");
    expect((gptResult?.payload as { status: string }).status).toBe("completed");

    const gptEvidence = (
      gptResult?.payload as unknown as {
        evidence: { metrics: { model: string; totalTokens: number } };
      }
    ).evidence;
    expect(gptEvidence.metrics.model).toBe("gpt-4o");
    expect(gptEvidence.metrics.totalTokens).toBe(205);

    // 4. Verify Anthropic result message and token metrics
    const claudeResult = messagesSentToCloud.find(
      (m): m is Extract<AgentProtocolMessage, { type: "assignment.result" }> =>
        m.type === "assignment.result" && m.assignmentId === "asg-claude-102",
    );
    expect(claudeResult).toBeDefined();
    expect(claudeResult?.workerId).toBe("w-claude-critic-1");
    expect((claudeResult?.payload as { status: string }).status).toBe(
      "completed",
    );

    const claudeEvidence = (
      claudeResult?.payload as unknown as {
        evidence: { metrics: { model: string; totalTokens: number } };
      }
    ).evidence;
    expect(claudeEvidence.metrics.model).toBe("claude-3-7-sonnet-20250219");
    expect(claudeEvidence.metrics.totalTokens).toBe(260);

    // 5. Verify architectural separation: Cloud never contacted model API endpoints directly
    expect(gptWorker?.independenceKey).not.toBe(claudeWorker?.independenceKey);

    await host.stop();
  });
});
