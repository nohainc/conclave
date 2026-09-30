import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { CliToolRunner } from "../cli_tool_runner.mjs";

async function waitForFile(path, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      return await readFile(path, "utf8");
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  }
  throw new Error(`timed out waiting for ${path}`);
}

async function expectHeartbeatStopped(path) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const before = await waitForFile(path);
    await new Promise((resolve) => setTimeout(resolve, 150));
    const after = await readFile(path, "utf8");
    if (before === after) return;
  }
  assert.fail("provider grandchild continued after CLI cleanup");
}

test("cancellation cleans up the provider CLI and its grandchild", async (t) => {
  if (process.platform === "win32") {
    t.skip("POSIX process-tree assertions run on macOS and Linux");
  }
  const directory = await mkdtemp(join(tmpdir(), "conclave-cli-tree-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const providerPath = join(directory, "fake-provider.mjs");
  const heartbeatPath = join(directory, "heartbeat");
  const grandchildPidPath = join(directory, "grandchild.pid");
  await writeFile(providerPath, [
    'import { spawn } from "node:child_process";',
    'import { writeFile } from "node:fs/promises";',
    "const heartbeat = process.argv[2];",
    "const grandchildPidPath = process.argv[3];",
    'const grandchild = spawn(process.execPath, ["-e", "const fs = require(\\\'node:fs\\\'); setInterval(() => fs.writeFileSync(process.argv[1], String(Date.now())), 30); setInterval(() => {}, 1000);", heartbeat], { stdio: "ignore" });',
    "await writeFile(grandchildPidPath, String(grandchild.pid));",
    "setInterval(() => {}, 1000);",
    "",
  ].join("\n"));

  const controller = new AbortController();
  const runner = new CliToolRunner({
    executable: process.execPath,
    env: process.env,
    killGraceMs: 100,
  });
  const invocation = runner.runCommand(
    [providerPath, heartbeatPath, grandchildPidPath],
    {
      timeoutMs: Number.POSITIVE_INFINITY,
      signal: controller.signal,
    },
  );
  const grandchildPid = await waitForFile(grandchildPidPath);
  const firstHeartbeat = await waitForFile(heartbeatPath);
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.notEqual(await readFile(heartbeatPath, "utf8"), firstHeartbeat);
  controller.abort();
  await assert.rejects(invocation, (error) => error.code === "cancelled");
  await expectHeartbeatStopped(heartbeatPath);
  assert.ok(Number(grandchildPid) > 0);
});
