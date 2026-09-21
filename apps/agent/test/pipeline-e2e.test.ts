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

describe("Deterministic Test Worker E2E Pipeline (Cloud -> Agent -> Plugin -> Worker -> Result -> Cloud)", () => {
  let tmpDir: string;
  const messagesSentToCloud: AgentProtocolMessage[] = [];

  const echoWorkerConfig: DesiredWorker = {
    id: "w-echo-tester-1",
    workerId: "w-echo-tester-1",
    workspaceId: "ws-pipeline-test",
    agentId: "agent-pipeline-test",
    pluginId: "conclave.echo-worker",
    pluginVersionPolicy: "1.0.0",
    name: "Echo Deterministic Worker",
    roles: [
      "implementer",
      "reviewer",
      "tester",
      "evaluator",
      "architect",
      "coder",
    ],
    capabilities: ["code_execution", "file_system"],
    config: {
      echoPrefix: "CLOUD_VERIFIED_ECHO:",
      emitTestArtifact: true,
      simulateDelayMs: 20,
    },
    secretRefs: [],
    billingMode: "local_compute",
    independenceKey: "indep-echo-1",
    concurrencyLimit: 2,
    sessionPolicy: "stateless",
    enabled: true,
  };

  const mockTransport: CloudTransport = {
    async enrollAgent(_cloudUrl, token) {
      return {
        agentId: "agent-pipeline-test",
        workspaceId: "ws-pipeline-test",
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
            sessionId: "sess-pipeline-test",
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
                pluginId: "conclave.echo-worker",
                version: "1.0.0",
                packageR2Key: "plugins/echo-worker/1.0.0.tar.gz",
                packageDigest: "sha256-echo",
                signature: "sig-echo",
                permissions: ["workspace:read", "workspace:write"],
              },
            ],
            desiredWorkers: [echoWorkerConfig],
            activeAssignmentIds: [],
          },
        };
      }

      return undefined;
    },
  };

  beforeEach(() => {
    messagesSentToCloud.length = 0;
    tmpDir = path.join(os.tmpdir(), `conclave-pipeline-e2e-${Date.now()}`);
    fs.mkdirSync(tmpDir, { recursive: true });

    // Install the echo-worker fixture into the agent's plugin directory
    const pluginDir = path.join(
      tmpDir,
      "plugins",
      "conclave.echo-worker",
      "1.0.0",
    );
    fs.mkdirSync(pluginDir, { recursive: true });

    // Copy the fixture entrypoint into the installed plugin dir
    const fixtureSource = path.resolve(
      __dirname,
      "../../../packages/plugin-sdk/fixtures/echo-worker/index.mjs",
    );
    fs.copyFileSync(fixtureSource, path.join(pluginDir, "index.mjs"));
  });

  afterEach(() => {
    try {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    } catch {
      // ignore
    }
  });

  it("proves complete Cloud -> Agent -> Plugin -> Worker -> Result -> Cloud pipeline", async () => {
    const host = new ConclaveAgentHost({
      config: {
        homeDir: tmpDir,
        workspaceId: "ws-pipeline-test",
        agentId: "agent-pipeline-test",
        heartbeatIntervalMs: 5000,
      },
      transport: mockTransport,
    });

    // 1. Start Agent & Handshake with Cloud
    await host.start();
    expect(host.isOnline).toBe(true);

    // 2. Synchronize desired worker configuration from Cloud (reconcileJournal is called on start, or can be called explicitly)
    await host.reconcileJournal();
    const worker = host.workerManager.getWorker("w-echo-tester-1");
    expect(worker).toBeDefined();
    expect(worker?.name).toBe("Echo Deterministic Worker");

    // 3. Cloud dispatches assignment to the agent
    const assignmentStartMessage: AgentProtocolMessage = {
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: "msg-cloud-dispatch-101",
      timestamp: new Date().toISOString(),
      workspaceId: "ws-pipeline-test",
      agentId: "agent-pipeline-test",
      workerId: "w-echo-tester-1",
      runId: "run-pipeline-001",
      taskId: "task-deterministic-eval",
      attemptId: "att-001",
      assignmentId: "asg-pipeline-101",
      idempotencyKey: "idem-pipe-101",
      type: "assignment.start",
      payload: {
        pluginId: "conclave.echo-worker",
        resolvedPluginVersion: "1.0.0",
        role: "implementer",
        objective: "Compute deterministic validation payload",
        input: {
          testParam: 12345,
          operation: "ECHO_CHECK",
        },
        contextArtifactIds: ["art-in-1"],
        timeoutMs: 5000,
      },
    };

    // 4. Agent receives message and returns acceptance ack
    const ack = await host.handleIncomingMessage(assignmentStartMessage);
    expect(ack).toBeDefined();
    expect(ack?.type).toBe("assignment.ack");
    expect((ack?.payload as { accepted: boolean }).accepted).toBe(true);

    // 5. Wait for isolated worker plugin execution to complete
    const finished = await host.workerManager.waitForIdle(10000);
    expect(finished).toBe(true);

    // 6. Verify messages transmitted back to Cloud
    const progressMessages = messagesSentToCloud.filter(
      (m) =>
        m.type === "assignment.progress" &&
        m.assignmentId === "asg-pipeline-101",
    );
    expect(progressMessages.length).toBeGreaterThanOrEqual(2);

    const resultMessage = messagesSentToCloud.find(
      (m): m is Extract<AgentProtocolMessage, { type: "assignment.result" }> =>
        m.type === "assignment.result" && m.assignmentId === "asg-pipeline-101",
    );
    expect(resultMessage).toBeDefined();
    expect(resultMessage?.workerId).toBe("w-echo-tester-1");

    const resultPayload = resultMessage?.payload as {
      status: string;
      summary: string;
      output: Record<string, unknown>;
      artifactIds: string[];
      findings: Array<{ id: string; type: string }>;
      evidence: { metrics: Record<string, unknown>; logs: string[] };
    };

    expect(resultPayload.status).toBe("completed");
    expect(resultPayload.summary).toContain(
      "CLOUD_VERIFIED_ECHO: Successfully executed 'Compute deterministic validation payload'",
    );
    expect(resultPayload.output.echo).toBe(true);
    expect(resultPayload.output.deterministicStatus).toBe("SUCCESS");
    expect(resultPayload.output.receivedObjective).toBe(
      "Compute deterministic validation payload",
    );
    expect(resultPayload.output.receivedRole).toBe("implementer");
    expect(resultPayload.output.receivedInput).toEqual({
      testParam: 12345,
      operation: "ECHO_CHECK",
    });
    expect(resultPayload.artifactIds.length).toBeGreaterThan(0);
    expect(resultPayload.findings.length).toBeGreaterThan(0);
    expect(resultPayload.evidence.metrics.findingsCount).toBe(1);

    // 7. Verify generated artifact on disk in agent workspace
    const taskWorkDir = host.storage.getWorkDir(
      "run-pipeline-001",
      "task-deterministic-eval",
    );
    const evidenceFile = path.join(taskWorkDir, "echo-evidence.txt");
    expect(fs.existsSync(evidenceFile)).toBe(true);
    const evidenceContent = fs.readFileSync(evidenceFile, "utf-8");
    expect(evidenceContent).toContain("Echo Worker Evidence");
    expect(evidenceContent).toContain(
      "Compute deterministic validation payload",
    );

    // 8. Verify journal lifecycle: acknowledged after successful delivery to Cloud
    expect(host.journal.get("asg-pipeline-101")).toBeUndefined();
    expect(host.journal.getUnreconciled().length).toBe(0);

    // 9. Stop host cleanly
    await host.stop();
    expect(host.isOnline).toBe(false);
  });

  it("handles plugin crash gracefully without corrupting host Agent runtime", async () => {
    const crashWorkerConfig: DesiredWorker = {
      id: "w-crash-1",
      workerId: "w-crash-1",
      workspaceId: "ws-pipeline-test",
      agentId: "agent-pipeline-test",
      pluginId: "conclave.crashing-worker",
      pluginVersionPolicy: "1.0.0",
      name: "Crashing Worker",
      roles: ["implementer"],
      capabilities: ["code_execution"],
      config: {},
      secretRefs: [],
      billingMode: "local_compute",
      independenceKey: "indep-crash-1",
      concurrencyLimit: 1,
      sessionPolicy: "stateless",
      enabled: true,
    };

    // Install crashing plugin
    const crashPluginDir = path.join(
      tmpDir,
      "plugins",
      "conclave.crashing-worker",
      "1.0.0",
    );
    fs.mkdirSync(crashPluginDir, { recursive: true });
    fs.writeFileSync(
      path.join(crashPluginDir, "index.mjs"),
      `
import readline from "node:readline";
const rl = readline.createInterface({ input: process.stdin, terminal: false });
for await (const line of rl) {
  console.error("CRITICAL: Out of memory in child worker process");
  process.exit(137);
}
`,
      "utf8",
    );

    const host = new ConclaveAgentHost({
      config: {
        homeDir: tmpDir,
        workspaceId: "ws-pipeline-test",
        agentId: "agent-pipeline-test",
      },
      transport: mockTransport,
    });

    await host.start();
    host.workerManager.configureWorker(crashWorkerConfig);

    const crashAssignmentMsg: AgentProtocolMessage = {
      protocol: AGENT_PROTOCOL_NAME,
      protocolVersion: AGENT_PROTOCOL_VERSION,
      messageId: "msg-crash-dispatch",
      timestamp: new Date().toISOString(),
      workspaceId: "ws-pipeline-test",
      agentId: "agent-pipeline-test",
      workerId: "w-crash-1",
      runId: "run-crash-001",
      taskId: "task-crash",
      attemptId: "att-crash-001",
      assignmentId: "asg-crash-101",
      idempotencyKey: "idem-crash-101",
      type: "assignment.start",
      payload: {
        pluginId: "conclave.crashing-worker",
        resolvedPluginVersion: "1.0.0",
        role: "implementer",
        objective: "Perform high-risk calculation",
        input: {},
        contextArtifactIds: [],
        timeoutMs: 5000,
      },
    };

    await host.handleIncomingMessage(crashAssignmentMsg);
    await host.workerManager.waitForIdle(5000);

    // Host should still be online and healthy
    expect(host.isOnline).toBe(true);

    // Error message should have been sent to Cloud
    const errorMsg = messagesSentToCloud.find(
      (m) =>
        m.type === "assignment.error" && m.assignmentId === "asg-crash-101",
    );
    expect(errorMsg).toBeDefined();
    const errorPayload = errorMsg?.payload as {
      status: string;
      error: { code: string; message: string };
    };
    expect(errorPayload.status).toBe("failed");
    expect(errorPayload.error.code).toBe("PLUGIN_CRASHED");

    await host.stop();
  });
});
