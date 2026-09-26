import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const adapter = fileURLToPath(
  new URL("../bin/conclave-ollama-adapter.mjs", import.meta.url),
);

test("Ollama adapter checks service and models, then executes selected model", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ollama-adapter-test-"));
  const mock = join(directory, "mock.mjs");
  await writeFile(
    mock,
    `globalThis.fetch = async (url, options = {}) => {
    const path = new URL(url).pathname;
    if (path === "/api/version") return new Response(JSON.stringify({ version: "0.6.0" }));
    if (path === "/api/tags") return new Response(JSON.stringify({ models: [{ name: "qwen:latest" }] }));
    if (path === "/api/chat") return new Response(JSON.stringify({ message: { content: JSON.parse(options.body).messages[0].content + " done" } }));
    return new Response("{}", { status: 404 });
  };`,
  );
  try {
    const child = spawn(process.execPath, [adapter], {
      env: { ...process.env, NODE_OPTIONS: `--import=${mock}` },
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
        workerTypeId: "ollama",
        adapterVersion: "1.0.0",
      }) + "\n",
    );
    child.stdin.write(
      JSON.stringify({
        type: "validate.request",
        protocolVersion: "1.0",
        requestId: "v",
        config: { endpointUrl: "http://localhost:11434" },
      }) + "\n",
    );
    child.stdin.write(
      JSON.stringify({
        type: "execute.request",
        protocolVersion: "1.0",
        requestId: "e",
        assignmentId: "a",
        model: "qwen:latest",
        prompt: "hello",
      }) + "\n",
    );
    child.stdin.end();
    await new Promise((resolve, reject) => {
      child.once("error", reject);
      child.once("close", resolve);
    });
    const frames = output.trim().split("\n").map(JSON.parse);
    const validation = frames.find((frame) => frame.type === "validate.result");
    assert.equal(validation.ready, true);
    assert.deepEqual(validation.models, ["qwen:latest"]);
    assert.equal(
      frames.find((frame) => frame.type === "result").output,
      "hello done",
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
