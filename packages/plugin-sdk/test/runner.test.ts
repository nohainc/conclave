import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { PluginProcessRunner } from "../src/runner.js";
import type { WorkerPluginInput } from "../src/types.js";

describe("PluginProcessRunner (Process Isolation & Crash Safety)", () => {
  let tmpDir: string;
  let workDir: string;

  beforeEach(() => {
    tmpDir = path.join(os.tmpdir(), `plugin-runner-test-${Date.now()}`);
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

  const baseInput: WorkerPluginInput = {
    objective: "Run automated static checks",
    role: "verifier",
    input: { checkType: "lint" },
    contextArtifactIds: ["art-1"],
    timeoutMs: 3000,
    config: { strict: true },
    secrets: {},
  };

  it("executes a child process plugin successfully with progress and artifact streaming", async () => {
    const scriptPath = path.join(tmpDir, "success-plugin.mjs");
    fs.writeFileSync(
      scriptPath,
      `
import readline from "node:readline";

const rl = readline.createInterface({ input: process.stdin, terminal: false });
for await (const line of rl) {
  const data = JSON.parse(line);
  console.log(JSON.stringify({ type: "progress", stage: "analyzing", percent: 50, logChunk: "Analyzing AST" }));
  console.log(JSON.stringify({ type: "artifact", artifactId: "art-generated-1" }));
  console.log(JSON.stringify({
    type: "result",
    output: {
      status: "completed",
      summary: "Verification passed with 0 errors",
      output: { passed: true },
      artifactIds: ["art-generated-1"],
      findings: [{ rule: "no-eval", status: "pass" }]
    }
  }));
  process.exit(0);
}
`,
      "utf8",
    );

    const runner = new PluginProcessRunner({
      pluginDir: tmpDir,
      entrypoint: "success-plugin.mjs",
    });

    const progressUpdates: string[] = [];
    const output = await runner.execute(baseInput, {
      workDir,
      signal: new AbortController().signal,
      onProgress: (stage) => progressUpdates.push(stage),
    });

    expect(output.status).toBe("completed");
    expect(output.summary).toContain("Verification passed");
    expect(output.artifactIds).toContain("art-generated-1");
    expect(progressUpdates).toContain("analyzing");
  });

  it("handles a fatal plugin crash without crashing the host process", async () => {
    const scriptPath = path.join(tmpDir, "crash-plugin.mjs");
    fs.writeFileSync(
      scriptPath,
      `
import readline from "node:readline";

const rl = readline.createInterface({ input: process.stdin, terminal: false });
for await (const line of rl) {
  console.error("FATAL: Plugin encountered segmentation fault or memory corruption");
  process.exit(139); // simulated SIGSEGV exit code
}
`,
      "utf8",
    );

    const runner = new PluginProcessRunner({
      pluginDir: tmpDir,
      entrypoint: "crash-plugin.mjs",
    });

    const output = await runner.execute(baseInput, {
      workDir,
      signal: new AbortController().signal,
    });

    // The host process did not crash! Output is safely captured as failed.
    expect(output.status).toBe("failed");
    expect(output.error?.code).toBe("PLUGIN_CRASHED");
    expect(output.error?.message).toContain(
      "FATAL: Plugin encountered segmentation fault",
    );
  });

  it("handles an unhandled exception thrown in plugin script cleanly", async () => {
    const scriptPath = path.join(tmpDir, "throw-plugin.mjs");
    fs.writeFileSync(
      scriptPath,
      `
throw new Error("Unexpected null pointer in native module binding");
`,
      "utf8",
    );

    const runner = new PluginProcessRunner({
      pluginDir: tmpDir,
      entrypoint: "throw-plugin.mjs",
    });

    const output = await runner.execute(baseInput, {
      workDir,
      signal: new AbortController().signal,
    });

    expect(output.status).toBe("failed");
    expect(output.error?.code).toBe("PLUGIN_CRASHED");
    expect(output.error?.message).toContain(
      "Unexpected null pointer in native module",
    );
  });

  it("terminates hanging plugin on timeout without blocking host", async () => {
    const scriptPath = path.join(tmpDir, "hang-plugin.mjs");
    fs.writeFileSync(
      scriptPath,
      `
import readline from "node:readline";

const rl = readline.createInterface({ input: process.stdin, terminal: false });
for await (const line of rl) {
  // Hang indefinitely
  setInterval(() => {}, 1000);
}
`,
      "utf8",
    );

    const runner = new PluginProcessRunner({
      pluginDir: tmpDir,
      entrypoint: "hang-plugin.mjs",
    });

    const output = await runner.execute(
      { ...baseInput, timeoutMs: 500 },
      {
        workDir,
        signal: new AbortController().signal,
      },
    );

    expect(output.status).toBe("failed");
    expect(output.error?.code).toBe("PLUGIN_TIMEOUT");
    expect(output.error?.message).toContain("exceeded maximum allowed runtime");
  });
});
