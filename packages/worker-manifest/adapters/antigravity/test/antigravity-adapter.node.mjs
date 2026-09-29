import { spawn } from "node:child_process";
import {
  chmod,
  mkdtemp,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { once } from "node:events";
import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";

const adapter = fileURLToPath(
  new URL("../bin/conclave-antigravity-adapter.mjs", import.meta.url),
);

async function startAdapter(env, cwd = process.cwd()) {
  const child = spawn(process.execPath, [adapter], {
    cwd,
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
    waitFor(predicate, timeoutMs = 5000) {
      const existing = frames.find(predicate);
      if (existing) return Promise.resolve(existing);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error("timed out waiting for adapter frame")),
          timeoutMs,
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

test("probes the CLI and streams a sandboxed headless execution result", async (t) => {
  const temp = await mkdtemp(join(tmpdir(), "conclave-antigravity-adapter-"));
  t.after(() => rm(temp, { recursive: true, force: true }));
  const bin = join(temp, "bin");
  await import("node:fs/promises").then(({ mkdir }) => mkdir(bin));
  const argsFile = join(temp, "args.txt");
  const childEnvFile = join(temp, "child-env.txt");
  const childCwdFile = join(temp, "child-cwd.txt");
  const fakeAgy = join(bin, "agy");
  await writeFile(
    fakeAgy,
    `#!/bin/sh
if [ "$1" = "--version" ]; then echo 'agy 4.5.6'; exit 0; fi
printf '%s\\n' "$*" > '${argsFile.replaceAll("'", "'\\''")}'
pwd > '${childCwdFile.replaceAll("'", "'\\''")}'
if [ -n "${"${GEMINI_API_KEY:-}"}" ]; then echo leaked > '${childEnvFile.replaceAll("'", "'\\''")}'; fi
cat >/dev/null
printf '%s\\n' '{"event":"init","conversation_id":"c1","init":{"cwd":"."}}'
printf '%s\\n' '{"event":"step_update","step_update":{"state":"RUNNING"}}'
printf '%s\\n' '{"event":"result","result":{"status":"SUCCESS","response":"Antigravity applied the change."}}'
`,
  );
  await chmod(fakeAgy, 0o755);
  const adapterProcess = await startAdapter(
    {
      ...process.env,
      CONCLAVE_CLI_EXECUTABLE: fakeAgy,
      GEMINI_API_KEY: "must-not-be-forwarded",
    },
    temp,
  );
  t.after(async () => {
    adapterProcess.child.stdin.end();
    if (adapterProcess.child.exitCode === null)
      adapterProcess.child.kill("SIGKILL");
    await once(adapterProcess.child, "close").catch(() => {});
  });
  adapterProcess.send({
    type: "initialize.request",
    protocolVersion: "2.1",
    requestId: "i1",
    workerTypeId: "antigravity",
    adapterVersion: "1.0.0",
  });
  assert.equal(
    (await adapterProcess.waitFor((frame) => frame.requestId === "i1")).type,
    "initialize.result",
  );
  adapterProcess.send({
    type: "probe.request",
    protocolVersion: "2.1",
    requestId: "v1",
  });
  assert.equal(
    (await adapterProcess.waitFor((frame) => frame.requestId === "v1")).ready,
    true,
  );
  assert.deepEqual(
    adapterProcess.frames.find((frame) => frame.requestId === "v1"),
    {
      type: "probe.result",
      protocolVersion: "2.1",
      requestId: "v1",
      ready: true,
      toolVersion: "4.5.6",
      checkKind: "readiness",
      issues: [],
    },
  );
  adapterProcess.send({
    type: "execute.request",
    protocolVersion: "2.1",
    requestId: "e1",
    assignmentId: "a1",
    prompt: "Make the change.",
    model: "gemini-3.7-flash",
  });
  const progress = await adapterProcess.waitFor(
    (frame) => frame.type === "progress",
  );
  assert.equal(progress.assignmentId, "a1");
  const result = await adapterProcess.waitFor(
    (frame) => frame.type === "result",
  );
  assert.equal(result.output, "Antigravity applied the change.");
  assert.equal(result.requestId, "e1");
  const args = await readFile(argsFile, "utf8");
  assert.match(args, /--input-format stream-json/);
  assert.match(args, /--output-format stream-json/);
  assert.match(args, /--sandbox/);
  assert.match(args, /--model gemini-3\.7-flash/);
  assert.ok(args.includes(`--sandbox`));
  assert.doesNotMatch(args, /--dangerously-skip-permissions/);
  assert.doesNotMatch(args, /--yolo/);
  assert.ok(args.includes(`--print-timeout 15m`));
  assert.equal(
    (await readFile(childCwdFile, "utf8")).trim(),
    await realpath(temp),
  );
  await assert.rejects(readFile(childEnvFile, "utf8"));

  adapterProcess.send({
    type: "execute.request",
    protocolVersion: "2.1",
    requestId: "e-default-model",
    assignmentId: "a-default-model",
    prompt: "Use the configured default model.",
  });
  const defaultModelResult = await adapterProcess.waitFor(
    (frame) => frame.requestId === "e-default-model" && frame.type === "result",
  );
  assert.equal(defaultModelResult.assignmentId, "a-default-model");
  assert.doesNotMatch(await readFile(argsFile, "utf8"), /--model/);
});

test("translates headless authentication failures to a safe reason code", async (t) => {
  const temp = await mkdtemp(join(tmpdir(), "conclave-antigravity-auth-"));
  t.after(() => rm(temp, { recursive: true, force: true }));
  const bin = join(temp, "bin");
  await import("node:fs/promises").then(({ mkdir }) => mkdir(bin));
  const fakeAgy = join(bin, "agy");
  await writeFile(
    fakeAgy,
    "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'agy 4.5.6'; exit 0; fi\necho 'Authentication required: provider-secret-detail' >&2\nexit 1\n",
  );
  await chmod(fakeAgy, 0o755);
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
    type: "probe.request",
    protocolVersion: "2.1",
    requestId: "v2",
  });
  const response = await adapterProcess.waitFor(
    (frame) => frame.requestId === "v2",
  );
  assert.equal(response.type, "probe.result");
  assert.equal(response.ready, true);
  adapterProcess.send({
    type: "execute.request",
    protocolVersion: "2.1",
    requestId: "e2",
    assignmentId: "readiness-test",
    prompt: "Reply with exactly the word OK. Do not use tools.",
  });
  const failure = await adapterProcess.waitFor(
    (frame) => frame.requestId === "e2",
  );
  assert.equal(failure.type, "error");
  assert.equal(failure.code, "authentication_required");
  assert.doesNotMatch(JSON.stringify(failure), /provider-secret-detail/);
});

test("translates permission configuration diagnostics to a safe reason code", async (t) => {
  const temp = await mkdtemp(
    join(tmpdir(), "conclave-antigravity-permissions-"),
  );
  t.after(() => rm(temp, { recursive: true, force: true }));
  const bin = join(temp, "bin");
  await import("node:fs/promises").then(({ mkdir }) => mkdir(bin));
  const fakeAgy = join(bin, "agy");
  await writeFile(
    fakeAgy,
    "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'agy 4.5.6'; exit 0; fi\necho 'Permission configuration is required for this workspace.' >&2\nexit 1\n",
  );
  await chmod(fakeAgy, 0o755);
  const adapterProcess = await startAdapter({
    ...process.env,
    CONCLAVE_CLI_EXECUTABLE: fakeAgy,
  });
  t.after(async () => {
    adapterProcess.child.stdin.end();
    if (adapterProcess.child.exitCode === null)
      adapterProcess.child.kill("SIGKILL");
    await once(adapterProcess.child, "close").catch(() => {});
  });
  adapterProcess.send({
    type: "execute.request",
    protocolVersion: "2.1",
    requestId: "e3",
    assignmentId: "readiness-test",
    prompt: "Reply with exactly the word OK. Do not use tools.",
  });
  const failure = await adapterProcess.waitFor(
    (frame) => frame.requestId === "e3",
  );
  assert.equal(failure.type, "error");
  assert.equal(failure.code, "permission_denied");
  assert.doesNotMatch(JSON.stringify(failure), /workspace\./);
});

test("maps provider failures to stable common execution codes", async (t) => {
  const cases = [
    ["invalid model selection: unknown model", "model_not_supported"],
    ["provider usage limit exceeded", "quota_exhausted"],
    ["provider unavailable with status 503", "provider_unavailable"],
    ["permission denied while invoking tool", "permission_denied"],
    ["internal request error", "execution_failed"],
  ];
  for (const [diagnostic, expectedCode] of cases) {
    const temp = await mkdtemp(join(tmpdir(), "conclave-antigravity-error-"));
    t.after(() => rm(temp, { recursive: true, force: true }));
    const fakeAgy = join(temp, "agy");
    await writeFile(
      fakeAgy,
      `#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{"event":"result","result":{"status":"ERROR","response":"","error":"${diagnostic}"}}'\nexit 1\n`,
    );
    await chmod(fakeAgy, 0o755);
    const adapterProcess = await startAdapter({
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      TMPDIR: process.env.TMPDIR,
      CONCLAVE_CLI_EXECUTABLE: fakeAgy,
    });
    t.after(async () => {
      adapterProcess.child.stdin.end();
      if (adapterProcess.child.exitCode === null)
        adapterProcess.child.kill("SIGKILL");
      await once(adapterProcess.child, "close").catch(() => {});
    });
    adapterProcess.send({
      type: "execute.request",
      protocolVersion: "2.1",
      requestId: `e-${expectedCode}`,
      assignmentId: "a1",
      prompt: "test",
    });
    const failure = await adapterProcess.waitFor(
      (frame) => frame.requestId === `e-${expectedCode}`,
    );
    assert.equal(failure.type, "error");
    assert.equal(failure.code, expectedCode);
    assert.doesNotMatch(JSON.stringify(failure), new RegExp(diagnostic));
  }
});

test("reports an unavailable agy executable with a stable code", async (t) => {
  const temp = await mkdtemp(join(tmpdir(), "conclave-antigravity-missing-"));
  t.after(() => rm(temp, { recursive: true, force: true }));
  const adapterProcess = await startAdapter({
    PATH: process.env.PATH,
    HOME: process.env.HOME,
    TMPDIR: process.env.TMPDIR,
    CONCLAVE_CLI_EXECUTABLE: join(temp, "missing-agy"),
  });
  t.after(async () => {
    adapterProcess.child.stdin.end();
    if (adapterProcess.child.exitCode === null)
      adapterProcess.child.kill("SIGKILL");
    await once(adapterProcess.child, "close").catch(() => {});
  });
  adapterProcess.send({
    type: "execute.request",
    protocolVersion: "2.1",
    requestId: "e-missing",
    assignmentId: "a-missing",
    prompt: "test",
  });
  const failure = await adapterProcess.waitFor(
    (frame) => frame.requestId === "e-missing",
  );
  assert.equal(failure.type, "error");
  assert.equal(failure.code, "cli_not_found");
  assert.doesNotMatch(JSON.stringify(failure), /missing-agy/);
});

test(
  "runs a real agy assignment only when explicitly opted in",
  {
    skip: process.env.CONCLAVE_TEST_REAL_AGY !== "1",
  },
  async (t) => {
    const adapterProcess = await startAdapter({
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      TMPDIR: process.env.TMPDIR,
      LANG: process.env.LANG,
      CONCLAVE_CLI_EXECUTABLE: process.env.CONCLAVE_TEST_AGY_PATH || "agy",
    });
    t.after(async () => {
      adapterProcess.child.stdin.end();
      if (adapterProcess.child.exitCode === null)
        adapterProcess.child.kill("SIGKILL");
      await once(adapterProcess.child, "close").catch(() => {});
    });
    adapterProcess.send({
      type: "execute.request",
      protocolVersion: "2.1",
      requestId: "real-agy-execution",
      assignmentId: "real-agy-assignment",
      prompt: "Reply with exactly OK. Do not use tools.",
    });
    const result = await adapterProcess.waitFor(
      (frame) =>
        frame.requestId === "real-agy-execution" && frame.type === "result",
      300_000,
    );
    assert.equal(result.assignmentId, "real-agy-assignment");
    assert.match(result.output, /OK/);
    assert.deepEqual(result.artifacts, []);
  },
);
