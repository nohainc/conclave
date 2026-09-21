import { describe, expect, it } from "vitest";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  webAiWorkerManifest,
  executeWebAiWorker,
  buildWebAiPrompt,
  validateWorkerPluginManifest,
  PluginProcessRunner,
  type WorkerPluginInput,
  type WorkerPluginContext,
} from "../src/index.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

describe("Web / Cloud AI Worker Plugin (conclave.web-ai)", () => {
  const dummyContext: WorkerPluginContext = {
    workDir: process.cwd(),
    signal: new AbortController().signal,
    config: {},
    secrets: {},
    log: () => {},
    progress: () => {},
    emitArtifact: () => {},
    emitFinding: () => {},
  };

  it("has valid manifest metadata and schemas", () => {
    expect(() =>
      validateWorkerPluginManifest(webAiWorkerManifest),
    ).not.toThrow();
    expect(webAiWorkerManifest.pluginId).toBe("conclave.web-ai");
    expect(webAiWorkerManifest.capabilities).toContain("web_chat");
    expect(webAiWorkerManifest.capabilities).toContain("interactive_relay");
  });

  it("builds structured prompt for web AI session", () => {
    const prompt = buildWebAiPrompt({
      role: "architect",
      objective: "Evaluate edge runtime caching",
      input: { cacheTtlSeconds: 300 },
      contextArtifactIds: ["art-schema-1"],
      timeoutMs: 5000,
      config: {},
      secrets: {},
    });

    expect(prompt).toContain("Task Assignment: ARCHITECT");
    expect(prompt).toContain("Evaluate edge runtime caching");
    expect(prompt).toContain("cacheTtlSeconds");
    expect(prompt).toContain("art-schema-1");
  });

  it("registers task with Cloud relay and polls for completion", async () => {
    const registeredTasks: unknown[] = [];
    let pollCount = 0;

    const mockFetch = async (
      input: RequestInfo | URL,
      init?: RequestInit,
    ): Promise<Response> => {
      const url = String(input);
      if (url.endsWith("/tasks/register")) {
        registeredTasks.push(JSON.parse(String(init?.body || "{}")));
        return new Response(JSON.stringify({ status: "queued" }), {
          status: 200,
        });
      }

      if (url.includes("/tasks/asg-web-test-1/status")) {
        pollCount++;
        if (pollCount === 1) {
          return new Response(
            JSON.stringify({ status: "claimed", progress: 50 }),
            { status: 200 },
          );
        }
        return new Response(
          JSON.stringify({
            status: "completed",
            summary: "Evaluated caching architecture via ChatGPT Web",
            result: { strategy: "Edge KV + Cache-Control max-age=300" },
            findings: ["Low cold start", "High cache hit ratio"],
            artifactIds: ["art-caching-report"],
          }),
          { status: 200 },
        );
      }

      return new Response("Not found", { status: 404 });
    };

    const pluginInput: WorkerPluginInput = {
      role: "architect",
      objective: "Design edge caching strategy",
      input: { taskId: "asg-web-test-1" },
      contextArtifactIds: [],
      timeoutMs: 5000,
      config: {
        relayUrl: "https://cloud.conclave.local/api/v2/connector",
        targetPlatform: "chatgpt_web",
        pollIntervalMs: 10,
        timeoutMs: 5000,
      },
      secrets: {},
    };

    const result = await executeWebAiWorker(
      pluginInput,
      dummyContext,
      mockFetch,
    );

    expect(result.status).toBe("completed");
    expect(result.summary).toContain("ChatGPT Web");
    expect(result.output?.strategy).toBe("Edge KV + Cache-Control max-age=300");
    expect(result.findings).toHaveLength(2);
    expect(registeredTasks).toHaveLength(1);
  });

  it("handles failure reported by web AI session", async () => {
    const mockFetch = async (input: RequestInfo | URL): Promise<Response> => {
      const url = String(input);
      if (url.endsWith("/tasks/register")) {
        return new Response(JSON.stringify({ status: "queued" }), {
          status: 200,
        });
      }

      if (url.includes("/tasks/asg-fail-1/status")) {
        return new Response(
          JSON.stringify({
            status: "failed",
            error: {
              code: "RATE_LIMITED_WEB_SESSION",
              message: "ChatGPT Web session hit rate limit",
              retryable: true,
            },
          }),
          { status: 200 },
        );
      }

      return new Response("Not found", { status: 404 });
    };

    const result = await executeWebAiWorker(
      {
        role: "architect",
        objective: "High volume prompt",
        input: { taskId: "asg-fail-1" },
        contextArtifactIds: [],
        timeoutMs: 2000,
        config: { pollIntervalMs: 10, timeoutMs: 2000 },
        secrets: {},
      },
      dummyContext,
      mockFetch,
    );

    expect(result.status).toBe("failed");
    expect(result.error?.code).toBe("RATE_LIMITED_WEB_SESSION");
    expect(result.error?.retryable).toBe(true);
  });

  it("executes standalone fixture out-of-process via PluginProcessRunner", async () => {
    const fixtureDir = path.resolve(__dirname, "../fixtures/web-ai");
    const runner = new PluginProcessRunner({
      pluginDir: fixtureDir,
      entrypoint: "index.mjs",
      executable: "node",
    });

    const progressLogs: string[] = [];
    const output = await runner.execute(
      {
        role: "reviewer",
        objective: "Review code via Web AI relay fixture",
        input: { taskId: "asg-process-web-1" },
        contextArtifactIds: [],
        timeoutMs: 5000,
        config: { targetPlatform: "claude_web" },
        secrets: {},
      },
      {
        workDir: process.cwd(),
        signal: new AbortController().signal,
        onProgress: (stage, pct, chunk) =>
          progressLogs.push(`${stage}:${pct}:${chunk || ""}`),
      },
    );

    expect(output.status).toBe("completed");
    expect(output.summary).toContain("claude_web");
    expect(output.output?.platform).toBe("claude_web");
    expect(progressLogs.length).toBeGreaterThan(0);
  });
});
