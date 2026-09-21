import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { EventEmitter } from "node:events";
import {
  claudeWorkerManifest,
  claudeWorkerDefinition,
  executeClaudeWorker,
  buildClaudePrompt,
  CLAUDE_PLUGIN_ID,
  type ClaudeSpawner,
  type ClaudeSpawnChild,
} from "../src/claude-plugin.js";
import { PluginProcessRunner } from "../src/runner.js";
import type { WorkerPluginContext, WorkerPluginInput } from "../src/types.js";

describe("Claude Code Worker Plugin", () => {
  let tmpDir: string;
  let workDir: string;

  beforeEach(() => {
    tmpDir = path.join(os.tmpdir(), `claude-plugin-test-${Date.now()}`);
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
    expect(claudeWorkerManifest.pluginId).toBe(CLAUDE_PLUGIN_ID);
    expect(claudeWorkerManifest.roles).toContain("implementer");
    expect(claudeWorkerManifest.roles).toContain("reviewer");
    expect(claudeWorkerManifest.roles).toContain("architect");
    expect(claudeWorkerManifest.capabilities).toContain("code_execution");
    expect(claudeWorkerManifest.capabilities).toContain("file_system");
    expect(claudeWorkerDefinition.manifest.pluginId).toBe(CLAUDE_PLUGIN_ID);
  });

  it("builds structured prompt from task input and repository context", () => {
    const prompt = buildClaudePrompt({
      objective: "Review multi-worker isolation invariants",
      role: "reviewer",
      input: { reviewArea: "security" },
      contextArtifactIds: ["art-review-guidelines"],
      timeoutMs: 15000,
      repository: {
        repositoryId: "repo-core",
        revision: "sha-claude-rev-1",
        workspaceSubpath: "packages/security",
      },
      config: {},
      secrets: {},
    });

    expect(prompt).toContain("Review multi-worker isolation invariants");
    expect(prompt).toContain("Assigned Role:\nreviewer");
    expect(prompt).toContain("art-review-guidelines");
    expect(prompt).toContain("sha-claude-rev-1");
  });

  it("executes simulated Claude Code CLI with progress, stdout capture, and result normalization", async () => {
    const progressUpdates: string[] = [];
    const emittedFindings: unknown[] = [];

    const mockContext: WorkerPluginContext = {
      workDir,
      signal: new AbortController().signal,
      config: {
        executable: "claude",
        args: ["-p", "--output-format", "json"],
      },
      secrets: {
        ANTHROPIC_API_KEY: "sk-ant-test-key-9999",
      },
      log: () => {},
      progress: (stage) => progressUpdates.push(stage),
      emitArtifact: () => {},
      emitFinding: (f) => emittedFindings.push(f),
    };

    const mockSpawner: ClaudeSpawner = () => {
      const emitter = new EventEmitter() as EventEmitter & ClaudeSpawnChild;
      const stdoutEmitter = new EventEmitter();
      const stderrEmitter = new EventEmitter();

      Object.assign(emitter, {
        pid: 7766,
        stdout: stdoutEmitter,
        stderr: stderrEmitter,
        kill: () => {},
      });

      setTimeout(() => {
        const responseJson = JSON.stringify({
          messageType: "ImplementationResult",
          payload: {
            status: "completed",
            summary: "Comprehensive architecture review completed",
            output: { passed: true, score: 98 },
            findings: [
              {
                id: "claude-finding-1",
                type: "security_review",
                title:
                  "Local credentials properly isolated from persistent storage",
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
      objective: "Conduct security review of worker credential passing",
      role: "reviewer",
      input: { scope: "worker-secrets" },
      contextArtifactIds: [],
      timeoutMs: 5000,
      config: {},
      secrets: {},
    };

    const output = await executeClaudeWorker(input, mockContext, mockSpawner);

    expect(output.status).toBe("completed");
    expect(output.summary).toBe("Comprehensive architecture review completed");
    expect(output.output).toBeDefined();
    expect(output.findings?.length).toBe(1);
    expect(output.evidence?.metrics?.exitCode).toBe(0);
    expect(progressUpdates).toContain("init");
    expect(progressUpdates).toContain("executing_cli");
    expect(progressUpdates).toContain("parsing_output");
    expect(progressUpdates).toContain("completed");
  });

  it("runs out-of-process via PluginProcessRunner fixture", async () => {
    const fixtureDir = path.resolve(__dirname, "../fixtures/claude");
    const runner = new PluginProcessRunner({
      pluginDir: fixtureDir,
      entrypoint: "index.mjs",
      executable: "node",
    });

    const progressLogs: string[] = [];
    const output = await runner.execute(
      {
        objective: "Execute out-of-process claude task",
        role: "reviewer",
        input: { pr: 42 },
        contextArtifactIds: ["art-diff-1"],
        timeoutMs: 5000,
        config: {},
        secrets: { ANTHROPIC_API_KEY: "sk-ant-local-secret" },
      },
      {
        workDir,
        signal: new AbortController().signal,
        onProgress: (stage, pct, chunk) =>
          progressLogs.push(`${stage}:${pct}:${chunk || ""}`),
      },
    );

    expect(output.status).toBe("completed");
    expect(output.summary).toContain("Claude Code successfully completed");
    expect(output.output?.provider).toBe("anthropic-claude");
    expect(progressLogs.some((l) => l.startsWith("init:"))).toBe(true);
    expect(progressLogs.some((l) => l.startsWith("executing_cli:"))).toBe(true);
  });
});
