import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import {
  openaiApiWorkerManifest,
  openaiApiWorkerDefinition,
  executeOpenAIApiWorker,
  buildOpenAIMessages,
  OPENAI_API_PLUGIN_ID,
  type FetchTransport,
} from "../src/openai-api-plugin.js";
import { PluginProcessRunner } from "../src/runner.js";
import type { WorkerPluginContext, WorkerPluginInput } from "../src/types.js";

describe("OpenAI API Worker Plugin", () => {
  let tmpDir: string;
  let workDir: string;

  beforeEach(() => {
    tmpDir = path.join(os.tmpdir(), `openai-api-test-${Date.now()}`);
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
    expect(openaiApiWorkerManifest.pluginId).toBe(OPENAI_API_PLUGIN_ID);
    expect(openaiApiWorkerManifest.roles).toContain("architect");
    expect(openaiApiWorkerManifest.roles).toContain("reviewer");
    expect(openaiApiWorkerManifest.capabilities).toContain("code_execution");
    expect(openaiApiWorkerManifest.capabilities).toContain("network");
    expect(openaiApiWorkerDefinition.manifest.pluginId).toBe(
      OPENAI_API_PLUGIN_ID,
    );
  });

  it("builds structured OpenAI messages payload from task input", () => {
    const messages = buildOpenAIMessages({
      objective: "Design distributed queue consensus protocol",
      role: "architect",
      input: { protocolName: "RaftLite" },
      contextArtifactIds: ["art-reqs-1"],
      timeoutMs: 10000,
      repository: {
        repositoryId: "repo-consensus",
        revision: "rev-101",
      },
      config: {},
      secrets: {},
    });

    expect(messages.length).toBe(2);
    expect(messages[0]?.role).toBe("system");
    expect(messages[0]?.content).toContain("Assigned Role: architect");
    expect(messages[1]?.role).toBe("user");
    expect(messages[1]?.content).toContain("RaftLite");
    expect(messages[1]?.content).toContain("art-reqs-1");
  });

  it("returns an error if local OPENAI_API_KEY is missing", async () => {
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
      role: "coder",
      input: {},
      contextArtifactIds: [],
      timeoutMs: 5000,
      config: {},
      secrets: {},
    };

    const output = await executeOpenAIApiWorker(input, mockContext);
    expect(output.status).toBe("failed");
    expect(output.error?.code).toBe("MISSING_API_KEY");
  });

  it("executes OpenAI API call successfully with mock transport, progress events, and token accounting", async () => {
    const progressUpdates: string[] = [];
    const emittedFindings: unknown[] = [];

    const mockContext: WorkerPluginContext = {
      workDir,
      signal: new AbortController().signal,
      config: {
        model: "gpt-4o",
        temperature: 0.1,
        responseFormat: "json_object",
      },
      secrets: {
        OPENAI_API_KEY: "sk-test-local-key-valid",
      },
      log: () => {},
      progress: (stage) => progressUpdates.push(stage),
      emitArtifact: () => {},
      emitFinding: (f) => emittedFindings.push(f),
    };

    const mockFetch: FetchTransport = async (_input, init) => {
      expect(init?.method).toBe("POST");
      const headers = init?.headers as Record<string, string>;
      expect(headers.Authorization).toBe("Bearer sk-test-local-key-valid");

      const responseBody = {
        id: "chatcmpl-test-9911",
        object: "chat.completion",
        created: Date.now(),
        model: "gpt-4o",
        choices: [
          {
            index: 0,
            message: {
              role: "assistant",
              content: JSON.stringify({
                status: "completed",
                summary: "Designed RaftLite protocol with 3-node quorum",
                output: { quorumSize: 2, leaderHeartbeatMs: 150 },
                findings: [
                  {
                    id: "finding-raft-1",
                    type: "architecture_review",
                    title: "Quorum size 2 satisfies N=3 consensus",
                  },
                ],
              }),
            },
            finish_reason: "stop",
          },
        ],
        usage: {
          prompt_tokens: 180,
          completion_tokens: 95,
          total_tokens: 275,
        },
      };

      return new Response(JSON.stringify(responseBody), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    };

    const input: WorkerPluginInput = {
      objective: "Design distributed queue consensus protocol",
      role: "architect",
      input: { protocolName: "RaftLite" },
      contextArtifactIds: [],
      timeoutMs: 5000,
      config: {},
      secrets: {},
    };

    const output = await executeOpenAIApiWorker(input, mockContext, mockFetch);

    expect(output.status).toBe("completed");
    expect(output.summary).toBe(
      "Designed RaftLite protocol with 3-node quorum",
    );
    expect(output.output).toBeDefined();
    expect(output.findings?.length).toBe(1);
    expect(output.evidence?.metrics?.inputTokens).toBe(180);
    expect(output.evidence?.metrics?.outputTokens).toBe(95);
    expect(output.evidence?.metrics?.totalTokens).toBe(275);
    expect(output.evidence?.metrics?.model).toBe("gpt-4o");
    expect(progressUpdates).toContain("init");
    expect(progressUpdates).toContain("calling_api");
    expect(progressUpdates).toContain("parsing_response");
    expect(progressUpdates).toContain("completed");
  });

  it("handles HTTP error status codes from OpenAI API with retryable classification", async () => {
    const mockContext: WorkerPluginContext = {
      workDir,
      signal: new AbortController().signal,
      config: {},
      secrets: {
        OPENAI_API_KEY: "sk-test-key",
      },
      log: () => {},
      progress: () => {},
      emitArtifact: () => {},
      emitFinding: () => {},
    };

    const mockFetchRateLimit: FetchTransport = async () => {
      return new Response(
        JSON.stringify({ error: { message: "Rate limit exceeded" } }),
        {
          status: 429,
          headers: { "Content-Type": "application/json" },
        },
      );
    };

    const input: WorkerPluginInput = {
      objective: "Execute task under load",
      role: "coder",
      input: {},
      contextArtifactIds: [],
      timeoutMs: 5000,
      config: {},
      secrets: {},
    };

    const output = await executeOpenAIApiWorker(
      input,
      mockContext,
      mockFetchRateLimit,
    );
    expect(output.status).toBe("failed");
    expect(output.error?.code).toBe("OPENAI_HTTP_429");
    expect(output.error?.retryable).toBe(true);
  });

  it("runs out-of-process via PluginProcessRunner fixture", async () => {
    const fixtureDir = path.resolve(__dirname, "../fixtures/openai-api");
    const runner = new PluginProcessRunner({
      pluginDir: fixtureDir,
      entrypoint: "index.mjs",
      executable: "node",
    });

    const progressLogs: string[] = [];
    const output = await runner.execute(
      {
        objective: "Execute out-of-process OpenAI API task",
        role: "architect",
        input: { target: "microservices" },
        contextArtifactIds: [],
        timeoutMs: 5000,
        config: { model: "o3-mini" },
        secrets: { OPENAI_API_KEY: "sk-local-test" },
      },
      {
        workDir,
        signal: new AbortController().signal,
        onProgress: (stage, pct, chunk) =>
          progressLogs.push(`${stage}:${pct}:${chunk || ""}`),
      },
    );

    expect(output.status).toBe("completed");
    expect(output.summary).toContain("OpenAI (o3-mini) successfully completed");
    expect(output.output?.provider).toBe("openai-api");
    expect(output.evidence?.metrics?.model).toBe("o3-mini");
    expect(progressLogs.some((l) => l.startsWith("init:"))).toBe(true);
    expect(progressLogs.some((l) => l.startsWith("calling_api:"))).toBe(true);
  });
});
