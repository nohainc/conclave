import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { EventEmitter } from "node:events";
import {
  codexWorkerManifest,
  codexWorkerDefinition,
  executeCodexWorker,
  buildCodexPrompt,
  parseCodexEnvelope,
  CODEX_PLUGIN_ID,
  type CodexSpawner,
  type CodexSpawnChild,
} from "../src/codex-plugin.js";
import { PluginProcessRunner } from "../src/runner.js";
import type { WorkerPluginContext, WorkerPluginInput } from "../src/types.js";

describe("Codex Worker Plugin", () => {
  let tmpDir: string;
  let workDir: string;

  beforeEach(() => {
    tmpDir = path.join(os.tmpdir(), `codex-plugin-test-${Date.now()}`);
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
    expect(codexWorkerManifest.pluginId).toBe(CODEX_PLUGIN_ID);
    expect(codexWorkerManifest.roles).toContain("implementer");
    expect(codexWorkerManifest.roles).toContain("coder");
    expect(codexWorkerManifest.roles).toContain("architect");
    expect(codexWorkerManifest.capabilities).toContain("code_execution");
    expect(codexWorkerManifest.capabilities).toContain("file_system");
    expect(codexWorkerDefinition.manifest.pluginId).toBe(CODEX_PLUGIN_ID);
  });

  it("builds structured prompt from task input, context artifacts, and repository info", () => {
    const prompt = buildCodexPrompt({
      objective: "Refactor database migrations to idempotent SQLite statements",
      role: "coder",
      input: { files: ["migrations/0001_initial.sql"] },
      contextArtifactIds: ["art-schema-v2"],
      timeoutMs: 10000,
      repository: {
        repositoryId: "repo-core",
        revision: "abc1234",
        workspaceSubpath: "src",
      },
      config: {},
      secrets: {},
    });

    expect(prompt).toContain(
      "Refactor database migrations to idempotent SQLite statements",
    );
    expect(prompt).toContain("Assigned Role:\ncoder");
    expect(prompt).toContain("migrations/0001_initial.sql");
    expect(prompt).toContain("art-schema-v2");
    expect(prompt).toContain("abc1234");
  });

  it("parses valid JSON protocol envelopes and markdown-fenced envelopes", () => {
    const rawJson = JSON.stringify({
      messageType: "ImplementationResult",
      payload: {
        status: "completed",
        summary: "Migration refactored successfully",
        modifiedFiles: ["migrations/0001_initial.sql"],
      },
    });

    const parsed1 = parseCodexEnvelope(rawJson);
    expect(parsed1?.messageType).toBe("ImplementationResult");
    expect(parsed1?.payload?.status).toBe("completed");

    const fencedJson = `
Some explanation before.
\`\`\`json
{
  "messageType": "ImplementationResult",
  "payload": {
    "status": "completed",
    "summary": "Fenced output parsed",
    "findings": [{"id": "f1", "title": "Check passed"}]
  }
}
\`\`\`
`;
    const parsed2 = parseCodexEnvelope(fencedJson);
    expect(parsed2?.payload?.summary).toBe("Fenced output parsed");
    expect((parsed2?.payload?.findings as unknown[])?.length).toBe(1);
  });

  it("executes simulated Codex CLI with progress, stdout capture, and result normalization", async () => {
    const progressUpdates: string[] = [];
    const emittedFindings: unknown[] = [];

    const mockContext: WorkerPluginContext = {
      workDir,
      signal: new AbortController().signal,
      config: {
        executable: "codex",
        args: ["exec", "--json"],
      },
      secrets: {
        OPENAI_API_KEY: "sk-local-test-key-12345",
      },
      log: () => {},
      progress: (stage) => progressUpdates.push(stage),
      emitArtifact: () => {},
      emitFinding: (f) => emittedFindings.push(f),
    };

    const mockSpawner: CodexSpawner = () => {
      const emitter = new EventEmitter() as EventEmitter & CodexSpawnChild;
      const stdoutEmitter = new EventEmitter();
      const stderrEmitter = new EventEmitter();

      Object.assign(emitter, {
        pid: 9988,
        stdout: stdoutEmitter,
        stderr: stderrEmitter,
        kill: () => {},
      });

      setTimeout(() => {
        const responseJson = JSON.stringify({
          messageType: "ImplementationResult",
          payload: {
            status: "completed",
            summary: "Successfully generated AST transformations",
            output: { refactored: true },
            findings: [
              {
                id: "codex-finding-1",
                type: "code_quality",
                title: "Optimized SQL index utilization",
              },
            ],
          },
        });
        stdoutEmitter.emit("data", Buffer.from(responseJson, "utf8"));
        emitter.emit("close", 0);
      }, 20);

      return emitter;
    };

    const input: WorkerPluginInput = {
      objective: "Generate AST transformations for database layer",
      role: "coder",
      input: { targetPackage: "persistence" },
      contextArtifactIds: [],
      timeoutMs: 5000,
      config: {},
      secrets: {},
    };

    const output = await executeCodexWorker(input, mockContext, mockSpawner);

    expect(output.status).toBe("completed");
    expect(output.summary).toBe("Successfully generated AST transformations");
    expect(output.output).toBeDefined();
    expect(output.findings?.length).toBe(1);
    expect(output.evidence?.metrics?.exitCode).toBe(0);
    expect(progressUpdates).toContain("init");
    expect(progressUpdates).toContain("executing_cli");
    expect(progressUpdates).toContain("parsing_output");
    expect(progressUpdates).toContain("completed");
  });

  it("handles cancellation via AbortSignal cleanly", async () => {
    const abortController = new AbortController();

    const mockContext: WorkerPluginContext = {
      workDir,
      signal: abortController.signal,
      config: {},
      secrets: {},
      log: () => {},
      progress: () => {},
      emitArtifact: () => {},
      emitFinding: () => {},
    };

    let killed = false;
    const mockSpawner: CodexSpawner = () => {
      const emitter = new EventEmitter() as EventEmitter & CodexSpawnChild;
      const stdoutEmitter = new EventEmitter();
      const stderrEmitter = new EventEmitter();

      Object.assign(emitter, {
        pid: 9989,
        stdout: stdoutEmitter,
        stderr: stderrEmitter,
        kill: () => {
          killed = true;
          emitter.emit("close", null);
        },
      });

      return emitter;
    };

    const input: WorkerPluginInput = {
      objective: "Long running architectural refactor",
      role: "architect",
      input: {},
      contextArtifactIds: [],
      timeoutMs: 10000,
      config: {},
      secrets: {},
    };

    const executionPromise = executeCodexWorker(
      input,
      mockContext,
      mockSpawner,
    );

    // Cancel after 10ms
    setTimeout(() => {
      abortController.abort();
    }, 10);

    const output = await executionPromise;
    expect(killed).toBe(true);
    expect(output.status).toBe("failed");
    expect(output.error?.code).toBe("CODEX_CANCELLED");
  });

  it("runs out-of-process via PluginProcessRunner fixture", async () => {
    const fixtureDir = path.resolve(__dirname, "../fixtures/codex");
    const runner = new PluginProcessRunner({
      pluginDir: fixtureDir,
      entrypoint: "index.mjs",
      executable: "node",
    });

    const progressLogs: string[] = [];
    const output = await runner.execute(
      {
        objective: "Execute out-of-process codex task",
        role: "implementer",
        input: { file: "test.ts" },
        contextArtifactIds: ["art-1"],
        timeoutMs: 5000,
        config: {},
        secrets: { OPENAI_API_KEY: "sk-local-123" },
      },
      {
        workDir,
        signal: new AbortController().signal,
        onProgress: (stage, pct, chunk) =>
          progressLogs.push(`${stage}:${pct}:${chunk || ""}`),
      },
    );

    expect(output.status).toBe("completed");
    expect(output.summary).toContain("Codex successfully completed");
    expect(output.output?.provider).toBe("openai-codex");
    expect(progressLogs.some((l) => l.startsWith("init:"))).toBe(true);
    expect(progressLogs.some((l) => l.startsWith("executing_cli:"))).toBe(true);
  });
});
