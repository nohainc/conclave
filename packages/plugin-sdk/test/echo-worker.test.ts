import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import {
  echoWorkerDefinition,
  echoWorkerManifest,
  executeEchoWorker,
  ECHO_WORKER_PLUGIN_ID,
} from "../src/echo-worker.js";
import { PluginProcessRunner } from "../src/runner.js";
import type { WorkerPluginContext, WorkerPluginInput } from "../src/types.js";

describe("Echo Test Worker Plugin", () => {
  let tmpDir: string;
  let workDir: string;

  beforeEach(() => {
    tmpDir = path.join(os.tmpdir(), `echo-worker-test-${Date.now()}`);
    workDir = path.join(tmpDir, "work");
    fs.mkdirSync(workDir, { recursive: true });
  });

  afterEach(() => {
    try {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    } catch {
      // ignore
    }
  });

  it("exports valid manifest conforming to Conclave Plugin specifications", () => {
    expect(echoWorkerManifest.pluginId).toBe(ECHO_WORKER_PLUGIN_ID);
    expect(echoWorkerManifest.roles).toContain("implementer");
    expect(echoWorkerManifest.roles).toContain("reviewer");
    expect(echoWorkerManifest.roles).toContain("coder");
    expect(echoWorkerManifest.capabilities).toContain("code_execution");
    expect(echoWorkerManifest.capabilities).toContain("file_system");
    expect(echoWorkerDefinition.manifest.pluginId).toBe(ECHO_WORKER_PLUGIN_ID);
    expect(typeof echoWorkerDefinition.execute).toBe("function");
  });

  it("executes directly and returns deterministic structured output with artifact and evidence", async () => {
    const logs: string[] = [];
    const progressUpdates: Array<{ stage: string; percent?: number }> = [];
    const emittedArtifacts: string[] = [];
    const emittedFindings: unknown[] = [];

    const mockContext: WorkerPluginContext = {
      workDir,
      signal: new AbortController().signal,
      config: {
        echoPrefix: "TEST_ECHO:",
        emitTestArtifact: true,
        simulateDelayMs: 5,
      },
      secrets: {},
      log: (level, msg) => logs.push(`[${level}] ${msg}`),
      progress: (stage, percent) => progressUpdates.push({ stage, percent }),
      emitArtifact: (id) => emittedArtifacts.push(id),
      emitFinding: (f) => emittedFindings.push(f),
    };

    const input: WorkerPluginInput = {
      objective: "Verify unit math calculations",
      role: "tester",
      input: { a: 40, b: 2, operation: "add" },
      contextArtifactIds: ["art-base-1"],
      timeoutMs: 5000,
      config: {},
      secrets: {},
    };

    const result = await executeEchoWorker(input, mockContext);

    expect(result.status).toBe("completed");
    expect(result.summary).toContain(
      "TEST_ECHO: Successfully executed 'Verify unit math calculations'",
    );
    expect(result.output).toBeDefined();
    expect(result.output?.echo).toBe(true);
    expect(result.output?.deterministicStatus).toBe("SUCCESS");
    expect(result.output?.receivedObjective).toBe(
      "Verify unit math calculations",
    );
    expect(result.output?.receivedRole).toBe("tester");
    expect(result.output?.receivedInput).toEqual({
      a: 40,
      b: 2,
      operation: "add",
    });
    expect(result.artifactIds.length).toBeGreaterThan(0);
    expect(result.findings?.length).toBeGreaterThan(0);
    expect(result.evidence?.metrics?.findingsCount).toBe(1);

    // Verify artifact file was created on disk
    const evidenceFile = path.join(workDir, "echo-evidence.txt");
    expect(fs.existsSync(evidenceFile)).toBe(true);
    const content = fs.readFileSync(evidenceFile, "utf-8");
    expect(content).toContain("Echo Worker Evidence");
    expect(content).toContain("Verify unit math calculations");
  });

  it("runs out-of-process via PluginProcessRunner", async () => {
    const fixtureDir = path.resolve(__dirname, "../fixtures/echo-worker");
    const runner = new PluginProcessRunner({
      pluginDir: fixtureDir,
      entrypoint: "index.mjs",
      executable: "node",
    });

    const progressLogs: string[] = [];
    const output = await runner.execute(
      {
        objective: "Execute out-of-process echo task",
        role: "coder",
        input: { target: "index.ts" },
        contextArtifactIds: [],
        timeoutMs: 5000,
        config: { simulateDelayMs: 0, emitTestArtifact: true },
        secrets: {},
      },
      {
        workDir,
        signal: new AbortController().signal,
        onProgress: (stage, pct, chunk) =>
          progressLogs.push(`${stage}:${pct}:${chunk || ""}`),
      },
    );

    expect(output.status).toBe("completed");
    expect(output.summary).toContain(
      "Successfully executed 'Execute out-of-process echo task'",
    );
    expect(output.output?.echo).toBe(true);
    expect(output.output?.receivedRole).toBe("coder");
    expect(progressLogs.some((l) => l.startsWith("init:"))).toBe(true);
    expect(progressLogs.some((l) => l.startsWith("completed:"))).toBe(true);
  });
});
