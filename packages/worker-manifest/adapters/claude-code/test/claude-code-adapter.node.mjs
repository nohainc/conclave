import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile, chmod } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const adapter = fileURLToPath(
  new URL("../bin/conclave-claude-code-adapter.mjs", import.meta.url),
);

test("Claude Code adapter validates auth and returns normalized headless output", async () => {
  const directory = await mkdtemp(join(tmpdir(), "claude-adapter-test-"));
  try {
    const cli = join(directory, "claude");
    await writeFile(
      cli,
      `#!/bin/sh\nif [ "$1" = "auth" ]; then exit 0; fi\ncat >/dev/null\nprintf '%s\\n' '{"type":"result","result":"Claude response","is_error":false}'\n`,
    );
    await chmod(cli, 0o755);
    const child = spawn(process.execPath, [adapter], {
      env: {
        ...process.env,
        PATH: `${directory}${delimiter}${process.env.PATH}`,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let output = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => (output += chunk));
    child.stdin.write(
      JSON.stringify({
        type: "initialize.request",
        protocolVersion: "1.0",
        requestId: "i",
        workerTypeId: "claude-code",
        adapterVersion: "1.0.0",
      }) + "\n",
    );
    child.stdin.write(
      JSON.stringify({
        type: "validate.request",
        protocolVersion: "1.0",
        requestId: "v",
        config: {},
      }) + "\n",
    );
    child.stdin.write(
      JSON.stringify({
        type: "execute.request",
        protocolVersion: "1.0",
        requestId: "e",
        assignmentId: "a",
        model: "",
        prompt: "hello",
      }) + "\n",
    );
    child.stdin.end();
    await new Promise((resolve, reject) => {
      child.once("error", reject);
      child.once("close", resolve);
    });
    const frames = output.trim().split("\n").map(JSON.parse);
    assert.equal(
      frames.find((frame) => frame.type === "validate.result").ready,
      true,
    );
    assert.equal(
      frames.find((frame) => frame.type === "result").output,
      "Claude response",
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
