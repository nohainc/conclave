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

describe("AI Worker Plugins E2E (Codex Main & Claude Reviewer on Host Agent)", () => {
  let tmpDir: string;
  const messagesSentToCloud: AgentProtocolMessage[] = [];

  const codexWorkerConfig: DesiredWorker = {
    id: "w-codex-main",
    workerId: "w-codex-main",
    workspaceId: "ws-ai-test",
    agentId: "agent-ai-host-1",
    pluginId: "conclave.codex",
    pluginVersionPolicy: "1.0.0",
    name: "Codex Main Implementer",
    roles: ["implementer", "coder", "architect"],
    capabilities: ["code_execution", "file_system", "git_ops"],
    config: {
      executable: "codex",
      args: ["exec", "--json", "--full-auto"],
    },
    secretRefs: ["OPENAI_API_KEY"],
    billingMode: "subscription",
    independenceKey: "indep-openai-pool",
    concurrencyLimit: 2,
    sessionPolicy: "isolated_workspace",
    enabled: true,
  };

  const claudeWorkerConfig: DesiredWorker = {
    id: "w-claude-reviewer",
    workerId: "w-claude-reviewer",
    workspaceId: "ws-ai-test",
    agentId: "agent-ai-host-1",
    pluginId: "conclave.claude-code",
    pluginVersionPolicy: "1.0.0",
    name: "Claude Senior Reviewer",
    roles: ["reviewer", "architect", "evaluator"],
    capabilities: ["code_execution", "file_system"],
    config: {
      executable: "claude",
      args: ["-p", "--output-format", "json"],
    },
    secretRefs: ["ANTHROPIC_API_KEY"],
    billingMode: "subscription",
    independenceKey: "indep-anthropic-pool",
    concurrencyLimit: 2,
    sessionPolicy: "stateless",
    enabled: true,
  };

  const mockTransport: CloudTransport = {
    async enrollAgent(_cloudUrl, token) {
      return {
        agentId: "agent-ai-host-1",
        workspaceId: "ws-ai-test",
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
            sessionId: "sess-ai-test",
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
                pluginId: "conclave.codex",
                version: "1.0.0",
                packageR2Key: "plugins/codex/1.0.0.tar.gz",
                packageDigest: "sha256-codex",
                signature: "sig-codex",
                permissions: [
                  "workspace:read",
                  "workspace:write",
                  "process:spawn",
                ],
              },
              {
                pluginId: "conclave.claude-code",
                version: "1.0.0",
                packageR2Key: "plugins/claude/1.0.0.tar.gz",
                packageDigest: "sha256-claude",
                signature: "sig-claude",
                permissions: [
                  "workspace:read",
                  "workspace:write",
                  "process:spawn",
                ],
              },
            ],
            desiredWorkers: [codexWorkerConfig, claudeWorkerConfig],
            activeAssignmentIds: [],
          },
        };
      }

      return undefined;
    },
  };

  beforeEach(() => {
    messagesSentToCloud.length = 0;
    tmpDir = path.join(os.tmpdir(), `conclave-ai-plugins-e2e-${Date.now()}`);
    fs.mkdirSync(tmpDir, { recursive: true });

    // Install Codex fixture into agent plugin dir
    const codexPluginDir = path.join(
      tmpDir,
      "plugins",
      "conclave.codex",
      "1.0.0",
    );
    fs.mkdirSync(codexPluginDir, { recursive: true });
    const codexFixtureSource = path.resolve(
      __dirname,
      "../../../packages/plugin-sdk/fixtures/codex/index.mjs",
    );
    fs.copyFileSync(codexFixtureSource, path.join(codexPluginDir, "index.mjs"));

    // Install Claude fixture into agent plugin dir
    const claudePluginDir = path.join(
      tmpDir,
      "plugins",
      "conclave.claude-code",
      "1.0.0",
    );
    fs.mkdirSync(claudePluginDir, { recursive: true });
    const claudeFixtureSource = path.resolve(
      __dirname,
      "../../../packages/plugin-sdk/fixtures/claude/index.mjs",
    );
    fs.copyFileSync(
      claudeFixtureSource,
      path.join(claudePluginDir, "index.mjs"),
    );
  });

  afterEach(() => {
    try {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    } catch {
      // ignore
    }
  });

  it("proves multi-worker execution of Codex implementer and Claude reviewer concurrently", async () => {
    const host = new ConclaveAgentHost({
      config: {
        homeDir: tmpDir,
        workspaceId: "ws-ai-test",
        agentId: "agent-ai-host-1",
        maxConcurrentWorkers: 4,
        heartbeatIntervalMs: 5000,
      },
      transport: mockTransport,
    });

    // 1. Start agent and sync workers
    await host.start();
    expect(host.isOnline).toBe(true);

    const codexWorker = host.workerManager.getWorker("w-codex-main");
    const claudeWorker = host.workerManager.getWorker("w-claude-reviewer");
    expect(codexWorker?.name).toBe("Codex Main Implementer");
    expect(claudeWorker?.name).toBe("Claude Senior Reviewer");

    // 2. Dispatch Codex Assignment (Implementation)
    const codexAssignmentMsg: AgentProtocolMessage = {
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: "msg-dispatch-codex-1",
      timestamp: new Date().toISOString(),
      workspaceId: "ws-ai-test",
      agentId: "agent-ai-host-1",
      workerId: "w-codex-main",
      runId: "run-ensemble-001",
      taskId: "task-implement",
      attemptId: "att-imp-1",
      assignmentId: "asg-codex-101",
      idempotencyKey: "idem-codex-101",
      type: "assignment.start",
      payload: {
        pluginId: "conclave.codex",
        resolvedPluginVersion: "1.0.0",
        role: "implementer",
        objective: "Implement resilient message retry queue",
        input: { language: "typescript" },
        contextArtifactIds: ["art-spec-1"],
        timeoutMs: 5000,
      },
    };

    // 3. Dispatch Claude Assignment (Independent Review)
    const claudeAssignmentMsg: AgentProtocolMessage = {
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: "msg-dispatch-claude-1",
      timestamp: new Date().toISOString(),
      workspaceId: "ws-ai-test",
      agentId: "agent-ai-host-1",
      workerId: "w-claude-reviewer",
      runId: "run-ensemble-001",
      taskId: "task-review",
      attemptId: "att-rev-1",
      assignmentId: "asg-claude-102",
      idempotencyKey: "idem-claude-102",
      type: "assignment.start",
      payload: {
        pluginId: "conclave.claude-code",
        resolvedPluginVersion: "1.0.0",
        role: "reviewer",
        objective: "Review retry queue for potential thread leaks",
        input: { targetTask: "task-implement" },
        contextArtifactIds: ["art-spec-1"],
        timeoutMs: 5000,
      },
    };

    // 4. Send both assignments concurrently to Agent Host
    const [ackCodex, ackClaude] = await Promise.all([
      host.handleIncomingMessage(codexAssignmentMsg),
      host.handleIncomingMessage(claudeAssignmentMsg),
    ]);

    expect((ackCodex?.payload as { accepted: boolean }).accepted).toBe(true);
    expect((ackClaude?.payload as { accepted: boolean }).accepted).toBe(true);

    // 5. Wait for both plugin executions to complete
    const finished = await host.workerManager.waitForIdle(10000);
    expect(finished).toBe(true);

    // 6. Verify Codex result message
    const codexResult = messagesSentToCloud.find(
      (m): m is Extract<AgentProtocolMessage, { type: "assignment.result" }> =>
        m.type === "assignment.result" && m.assignmentId === "asg-codex-101",
    );
    expect(codexResult).toBeDefined();
    expect(codexResult?.workerId).toBe("w-codex-main");
    expect((codexResult?.payload as { status: string }).status).toBe(
      "completed",
    );
    expect(
      (
        codexResult?.payload as unknown as {
          output: { provider: string };
        }
      ).output.provider,
    ).toBe("openai-codex");

    // 7. Verify Claude result message
    const claudeResult = messagesSentToCloud.find(
      (m): m is Extract<AgentProtocolMessage, { type: "assignment.result" }> =>
        m.type === "assignment.result" && m.assignmentId === "asg-claude-102",
    );
    expect(claudeResult).toBeDefined();
    expect(claudeResult?.workerId).toBe("w-claude-reviewer");
    expect((claudeResult?.payload as { status: string }).status).toBe(
      "completed",
    );
    expect(
      (
        claudeResult?.payload as unknown as {
          output: { provider: string };
        }
      ).output.provider,
    ).toBe("anthropic-claude");

    // 8. Verify anti-collusion independence keys are distinct
    expect(codexWorker?.independenceKey).not.toBe(
      claudeWorker?.independenceKey,
    );

    await host.stop();
  });
});
