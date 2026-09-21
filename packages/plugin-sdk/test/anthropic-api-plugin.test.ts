import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import {
  anthropicApiWorkerManifest,
  anthropicApiWorkerDefinition,
  executeAnthropicApiWorker,
  buildAnthropicMessagesPayload,
  ANTHROPIC_API_PLUGIN_ID,
} from "../src/anthropic-api-plugin.js";
import type { FetchTransport } from "../src/openai-api-plugin.js";
import { PluginProcessRunner } from "../src/runner.js";
import type { WorkerPluginContext, WorkerPluginInput } from "../src/types.js";

describe("Anthropic API Worker Plugin", () => {
  let tmpDir: string;
  let workDir: string;

  beforeEach(() => {
    tmpDir = path.join(os.tmpdir(), `anthropic-api-test-${Date.now()}`);
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
    expect(anthropicApiWorkerManifest.pluginId).toBe(ANTHROPIC_API_PLUGIN_ID);
    expect(anthropicApiWorkerManifest.roles).toContain("reviewer");
    expect(anthropicApiWorkerManifest.roles).toContain("architect");
    expect(anthropicApiWorkerManifest.capabilities).toContain("code_execution");
    expect(anthropicApiWorkerManifest.capabilities).toContain("network");
    expect(anthropicApiWorkerDefinition.manifest.pluginId).toBe(
      ANTHROPIC_API_PLUGIN_ID,
    );
  });

  it("builds structured Anthropic messages payload from task input", () => {
    const { system, messages } = buildAnthropicMessagesPayload({
      objective: "Perform formal verification of cryptography primitives",
      role: "reviewer",
      input: { algorithm: "Ed25519" },
      contextArtifactIds: ["art-crypto-spec"],
      timeoutMs: 12000,
      repository: {
        repositoryId: "repo-crypto",
        revision: "rev-202",
      },
      config: {},
      secrets: {},
    });

    expect(system).toContain("Assigned Role: reviewer");
    expect(messages.length).toBe(1);
    expect(messages[0]?.role).toBe("user");
    expect(messages[0]?.content).toContain("Ed25519");
    expect(messages[0]?.content).toContain("art-crypto-spec");
  });

  it("returns an error if local ANTHROPIC_API_KEY is missing", async () => {
    const mockContext: WorkerPluginContext = {
      workDir,
      signal: new AbortController().signal,
      config: {},
      secrets: {},
      log: () => {},
      progress: () => {},
      emitArtifact: () => {},
      emitFinding: () => {},
    };

    const input: WorkerPluginInput = {
      objective: "Test missing key",
      role: "reviewer",
      input: {},
      contextArtifactIds: [],
      timeoutMs: 5000,
      config: {},
      secrets: {},
    };

    const output = await executeAnthropicApiWorker(input, mockContext);
    expect(output.status).toBe("failed");
    expect(output.error?.code).toBe("MISSING_API_KEY");
  });

  it("executes Anthropic API call with mock transport and extracts token metrics", async () => {
    const progressUpdates: string[] = [];
    const emittedFindings: unknown[] = [];

    const mockContext: WorkerPluginContext = {
      workDir,
      signal: new AbortController().signal,
      config: {
        model: "claude-3-7-sonnet-20250219",
      },
      secrets: {
        ANTHROPIC_API_KEY: "sk-ant-test-valid-key-99",
      },
      log: () => {},
      progress: (stage) => progressUpdates.push(stage),
      emitArtifact: () => {},
      emitFinding: (f) => emittedFindings.push(f),
    };

    const mockFetch: FetchTransport = async (_input, init) => {
      expect(init?.method).toBe("POST");
      const headers = init?.headers as Record<string, string>;
      expect(headers["x-api-key"]).toBe("sk-ant-test-valid-key-99");
      expect(headers["anthropic-version"]).toBe("2023-06-01");

      const responseBody = {
        id: "msg_test_anthropic_77",
        type: "message",
        role: "assistant",
        model: "claude-3-7-sonnet-20250219",
        content: [
          {
            type: "text",
            text: JSON.stringify({
              status: "completed",
              summary:
                "Cryptographic validation completed with zero side-channel leaks",
              output: { passed: true, sideChannelResistance: "high" },
              findings: [
                {
                  id: "finding-crypto-1",
                  type: "cryptographic_audit",
                  title: "Constant-time multiplication verified",
                },
              ],
            }),
          },
        ],
        stop_reason: "end_turn",
        usage: {
          input_tokens: 210,
          output_tokens: 130,
        },
      };

      return new Response(JSON.stringify(responseBody), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    };

    const input: WorkerPluginInput = {
      objective: "Perform formal verification of cryptography primitives",
      role: "reviewer",
      input: { algorithm: "Ed25519" },
      contextArtifactIds: [],
      timeoutMs: 5000,
      config: {},
      secrets: {},
    };

    const output = await executeAnthropicApiWorker(
      input,
      mockContext,
      mockFetch,
    );

    expect(output.status).toBe("completed");
    expect(output.summary).toBe(
      "Cryptographic validation completed with zero side-channel leaks",
    );
    expect(output.output).toBeDefined();
    expect(output.findings?.length).toBe(1);
    expect(output.evidence?.metrics?.inputTokens).toBe(210);
    expect(output.evidence?.metrics?.outputTokens).toBe(130);
    expect(output.evidence?.metrics?.totalTokens).toBe(340);
    expect(progressUpdates).toContain("init");
    expect(progressUpdates).toContain("calling_api");
    expect(progressUpdates).toContain("parsing_response");
    expect(progressUpdates).toContain("completed");
  });

  it("runs out-of-process via PluginProcessRunner fixture", async () => {
    const fixtureDir = path.resolve(__dirname, "../fixtures/anthropic-api");
    const runner = new PluginProcessRunner({
      pluginDir: fixtureDir,
      entrypoint: "index.mjs",
      executable: "node",
    });

    const progressLogs: string[] = [];
    const output = await runner.execute(
      {
        objective: "Execute out-of-process Anthropic API task",
        role: "reviewer",
        input: { target: "auth-module" },
        contextArtifactIds: [],
        timeoutMs: 5000,
        config: { model: "claude-3-5-sonnet-20241022" },
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
    expect(output.summary).toContain(
      "Anthropic (claude-3-5-sonnet-20241022) successfully completed",
    );
    expect(output.output?.provider).toBe("anthropic-api");
    expect(output.evidence?.metrics?.model).toBe("claude-3-5-sonnet-20241022");
    expect(progressLogs.some((l) => l.startsWith("init:"))).toBe(true);
    expect(progressLogs.some((l) => l.startsWith("calling_api:"))).toBe(true);
  });
});
