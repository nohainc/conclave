import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import type { DesiredWorker } from "@conclave/agent-protocol";
import { loadAgentConfig } from "../src/config.js";
import { AgentStorage } from "../src/storage.js";
import { AgentLogger } from "../src/logger.js";
import { WorkerManager } from "../src/worker-manager.js";

describe("WorkerManager", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = path.join(os.tmpdir(), `agent-worker-test-${Date.now()}`);
    fs.mkdirSync(tmpDir, { recursive: true });
  });

  afterEach(() => {
    try {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    } catch {
      // ignore
    }
  });

  const mockWorker: DesiredWorker = {
    workerId: "w-codex-1",
    pluginId: "plugin-codex",
    pluginVersionPolicy: "1.0.0",
    name: "Codex Worker",
    roles: ["coder", "researcher"],
    capabilities: ["code_write", "git_ops"],
    config: {},
    secretRefs: [],
    billingMode: "local_compute",
    independenceKey: "indep-codex-1",
    concurrencyLimit: 2,
    enabled: true,
  };

  it("configures and retrieves worker statuses accurately", () => {
    const config = loadAgentConfig({ homeDir: tmpDir });
    const storage = new AgentStorage(config);
    const logger = new AgentLogger(config.logDir);
    const manager = new WorkerManager(config, storage, logger);

    manager.configureWorker(mockWorker);
    expect(manager.getWorker("w-codex-1")).toBeDefined();
    expect(manager.listWorkers().length).toBe(1);

    const status = manager.getWorkerStatus("w-codex-1");
    expect(status?.status).toBe("available");
    expect(status?.activeAssignments).toBe(0);
  });

  it("executes an assignment, tracks progress and returns success result", async () => {
    const config = loadAgentConfig({ homeDir: tmpDir });
    const storage = new AgentStorage(config);
    const logger = new AgentLogger(config.logDir);
    const manager = new WorkerManager(config, storage, logger);

    manager.configureWorker(mockWorker);

    const progressStages: string[] = [];
    const execution = await manager.executeAssignment({
      assignmentId: "asg-1",
      workerId: "w-codex-1",
      runId: "run-1",
      taskId: "task-1",
      attemptId: "att-1",
      idempotencyKey: "idem-1",
      payload: {
        objective: "Write unit tests for protocol",
        role: "coder",
        pluginId: "plugin-codex",
        resolvedPluginVersion: "1.0.0",
        input: { prompt: "test prompt" },
        contextArtifactIds: ["art-1"],
        timeoutMs: 5000,
      },
      onProgress: (stage) => {
        progressStages.push(stage);
      },
    });

    expect(execution.success).toBe(true);
    if (execution.success) {
      expect(execution.result.status).toBe("completed");
      expect(execution.result.summary).toContain("Successfully completed");
      expect(execution.result.artifactIds).toContain("art-1");
    }
    expect(progressStages).toContain("init");
    expect(progressStages).toContain("completed");
  });

  it("rejects execution if worker is not found", async () => {
    const config = loadAgentConfig({ homeDir: tmpDir });
    const storage = new AgentStorage(config);
    const logger = new AgentLogger(config.logDir);
    const manager = new WorkerManager(config, storage, logger);

    const execution = await manager.executeAssignment({
      assignmentId: "asg-2",
      workerId: "w-nonexistent",
      runId: "run-1",
      taskId: "task-1",
      attemptId: "att-1",
      idempotencyKey: "idem-2",
      payload: {
        objective: "Write tests",
        role: "coder",
        pluginId: "plugin-codex",
        resolvedPluginVersion: "1.0.0",
        input: {},
        contextArtifactIds: [],
        timeoutMs: 5000,
      },
    });

    expect(execution.success).toBe(false);
    if (!execution.success) {
      expect(execution.failure.error.code).toBe("WORKER_NOT_FOUND");
    }
  });

  it("supports multi-worker provisioning on a shared plugin and enforces concurrency limit", async () => {
    const config = loadAgentConfig({
      homeDir: tmpDir,
      maxConcurrentWorkers: 5,
    });
    const storage = new AgentStorage(config);
    const logger = new AgentLogger(config.logDir);
    const manager = new WorkerManager(config, storage, logger);

    const gptArchitect: DesiredWorker = {
      workerId: "w-gpt-architect",
      pluginId: "openai",
      pluginVersionPolicy: "^1.0",
      name: "GPT Architect",
      roles: ["architect"],
      capabilities: ["code_design"],
      config: { model: "o3-mini", temperature: 0.2 },
      secretRefs: ["OPENAI_API_KEY"],
      billingMode: "api_metered",
      costMetadata: { currency: "USD" },
      independenceKey: "key-gpt-arch",
      concurrencyLimit: 1,
      sessionPolicy: "isolated_workspace",
      enabled: true,
    };

    const gptReviewer: DesiredWorker = {
      workerId: "w-gpt-reviewer",
      pluginId: "openai",
      pluginVersionPolicy: "1.0.0",
      name: "GPT Reviewer",
      roles: ["reviewer"],
      capabilities: ["code_review"],
      config: { model: "gpt-4o", temperature: 0.0 },
      secretRefs: ["OPENAI_API_KEY"],
      billingMode: "subscription",
      independenceKey: "key-gpt-rev",
      concurrencyLimit: 2,
      sessionPolicy: "stateless",
      enabled: true,
    };

    manager.configureWorker(gptArchitect);
    manager.configureWorker(gptReviewer);

    expect(manager.listWorkers().length).toBe(2);
    expect(manager.getWorker("w-gpt-architect")?.sessionPolicy).toBe(
      "isolated_workspace",
    );
    expect(manager.getWorker("w-gpt-reviewer")?.sessionPolicy).toBe(
      "stateless",
    );

    // Check concurrency enforcement: simulate long-running execution for w-gpt-architect
    manager.setExecutor(async () => {
      await new Promise((resolve) => setTimeout(resolve, 50));
      return {
        output: { done: true },
        summary: "Execution completed",
      };
    });

    const execution1Promise = manager.executeAssignment({
      assignmentId: "asg-arch-1",
      workerId: "w-gpt-architect",
      runId: "run-1",
      taskId: "task-1",
      attemptId: "att-1",
      idempotencyKey: "idem-arch-1",
      payload: {
        objective: "Design ADR",
        role: "architect",
        pluginId: "openai",
        resolvedPluginVersion: "1.0.0",
        input: {},
        contextArtifactIds: [],
        timeoutMs: 5000,
      },
    });

    // Worker limit is 1, second assignment should be rejected as WORKER_BUSY
    const execution2 = await manager.executeAssignment({
      assignmentId: "asg-arch-2",
      workerId: "w-gpt-architect",
      runId: "run-1",
      taskId: "task-2",
      attemptId: "att-2",
      idempotencyKey: "idem-arch-2",
      payload: {
        objective: "Design another ADR",
        role: "architect",
        pluginId: "openai",
        resolvedPluginVersion: "1.0.0",
        input: {},
        contextArtifactIds: [],
        timeoutMs: 5000,
      },
    });

    expect(execution2.success).toBe(false);
    if (!execution2.success) {
      expect(execution2.failure.error.code).toBe("WORKER_BUSY");
    }

    const execution1 = await execution1Promise;
    expect(execution1.success).toBe(true);
  });
});
