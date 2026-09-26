import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile, chmod } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { once } from "node:events";
import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";

const adapter = fileURLToPath(
  new URL("../bin/conclave-codex-adapter.mjs", import.meta.url),
);

async function startAdapter(env) {
  const child = spawn(process.execPath, [adapter], {
    env,
    stdio: ["pipe", "pipe", "pipe"],
  });
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  const frames = [];
  const waiters = [];
  lines.on("line", (line) => {
    const frame = JSON.parse(line);
    frames.push(frame);
    for (const waiter of [...waiters]) {
      if (waiter.predicate(frame)) {
        waiters.splice(waiters.indexOf(waiter), 1);
        waiter.resolve(frame);
      }
    }
  });
  return {
    child,
    frames,
    send(frame) {
      child.stdin.write(`${JSON.stringify(frame)}\n`);
    },
    waitFor(predicate) {
      const existing = frames.find(predicate);
      if (existing) return Promise.resolve(existing);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error("timed out waiting for adapter frame")),
          5000,
        );
        waiters.push({
          predicate,
          resolve: (frame) => {
            clearTimeout(timer);
            resolve(frame);
          },
        });
      });
    },
  };
}

test("validates local Codex login and streams a sandboxed execution result", async (t) => {
  const temp = await mkdtemp(join(tmpdir(), "conclave-codex-adapter-"));
  t.after(() => rm(temp, { recursive: true, force: true }));
  const bin = join(temp, "bin");
  await import("node:fs/promises").then(({ mkdir }) => mkdir(bin));
  const argsFile = join(temp, "args.txt");
  const fakeCodex = join(bin, "codex");
  await writeFile(
    fakeCodex,
    `#!/bin/sh
if [ "$1" = "login" ]; then exit 0; fi
printf '%s\\n' "$*" > "$FAKE_ARGS_FILE"
cat >/dev/null
printf '%s\\n' '{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"working"}}'
printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Created the requested change."}}'
printf '%s\\n' '{"type":"turn.completed"}'
`,
  );
  await chmod(fakeCodex, 0o755);
  const adapterProcess = await startAdapter({
    ...process.env,
    PATH: `${bin}:${process.env.PATH}`,
    FAKE_ARGS_FILE: argsFile,
  });
  t.after(async () => {
    adapterProcess.child.stdin.end();
    if (adapterProcess.child.exitCode === null)
      adapterProcess.child.kill("SIGKILL");
    await once(adapterProcess.child, "close").catch(() => {});
  });
  adapterProcess.send({
    type: "initialize.request",
    protocolVersion: "1.0",
    requestId: "i1",
    workerTypeId: "codex",
    adapterVersion: "1.0.0",
  });
  assert.equal(
    (await adapterProcess.waitFor((frame) => frame.requestId === "i1")).type,
    "initialize.result",
  );
  adapterProcess.send({
    type: "validate.request",
    protocolVersion: "1.0",
    requestId: "v1",
    config: {},
  });
  assert.equal(
    (await adapterProcess.waitFor((frame) => frame.requestId === "v1")).ready,
    true,
  );
  adapterProcess.send({
    type: "execute.request",
    protocolVersion: "1.0",
    requestId: "e1",
    assignmentId: "a1",
    prompt: "Make the change.",
    model: "gpt-5.5",
  });
  const progress = await adapterProcess.waitFor(
    (frame) => frame.type === "progress",
  );
  assert.equal(progress.assignmentId, "a1");
  const result = await adapterProcess.waitFor(
    (frame) => frame.type === "result",
  );
  assert.equal(result.output, "Created the requested change.");
  assert.equal(result.requestId, "e1");
  const args = await readFile(argsFile, "utf8");
  assert.match(args, /--ask-for-approval never/);
  assert.match(args, /--sandbox workspace-write/);
  assert.match(args, /--model gpt-5\.5/);
});

test("reports local authentication required without exposing provider details", async (t) => {
  const temp = await mkdtemp(join(tmpdir(), "conclave-codex-auth-"));
  t.after(() => rm(temp, { recursive: true, force: true }));
  const bin = join(temp, "bin");
  await import("node:fs/promises").then(({ mkdir }) => mkdir(bin));
  const fakeCodex = join(bin, "codex");
  await writeFile(fakeCodex, "#!/bin/sh\nexit 1\n");
  await chmod(fakeCodex, 0o755);
  const adapterProcess = await startAdapter({
    ...process.env,
    PATH: `${bin}:${process.env.PATH}`,
  });
  t.after(async () => {
    adapterProcess.child.stdin.end();
    if (adapterProcess.child.exitCode === null)
      adapterProcess.child.kill("SIGKILL");
    await once(adapterProcess.child, "close").catch(() => {});
  });
  adapterProcess.send({
    type: "validate.request",
    protocolVersion: "1.0",
    requestId: "v2",
    config: {},
  });
  const response = await adapterProcess.waitFor(
    (frame) => frame.requestId === "v2",
  );
  assert.equal(response.type, "validate.result");
  assert.equal(response.ready, false);
  assert.match(response.issues[0].message, /Sign in to Codex on this computer/);
});
