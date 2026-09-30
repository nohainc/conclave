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
import { runLiveCliAcceptance } from "../../shared/test/live-cli-acceptance.mjs";

const adapter = fileURLToPath(
  new URL("../bin/conclave-codex-adapter.mjs", import.meta.url),
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

function shellQuote(value) {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

test("validates local Codex login and streams a sandboxed execution result", async (t) => {
  const temp = await mkdtemp(join(tmpdir(), "conclave-codex-adapter-"));
  t.after(() => rm(temp, { recursive: true, force: true }));
  const bin = join(temp, "bin");
  await import("node:fs/promises").then(({ mkdir }) => mkdir(bin));
  const argsFile = join(temp, "args.txt");
  const callsFile = join(temp, "calls.txt");
  const childEnvFile = join(temp, "child-env.txt");
  const fakeCodex = join(bin, "codex");
  await writeFile(
    fakeCodex,
    `#!/bin/sh
printf '%s\\n' "$*" >> ${shellQuote(callsFile)}
if [ "$1" = "login" ]; then exit 0; fi
if [ "$1" = "--version" ]; then echo 'codex 1.2.3'; exit 0; fi
printf '%s\\n' "$*" > ${shellQuote(argsFile)}
if [ -n "${"${OPENAI_API_KEY:-}"}" ]; then echo leaked > ${shellQuote(childEnvFile)}; fi
cat >/dev/null
printf '%s\\n' '{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"working"}}'
printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Created the requested change."}}'
printf '%s\\n' '{"type":"turn.completed"}'
`,
  );
  await chmod(fakeCodex, 0o755);
  const adapterProcess = await startAdapter(
    {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ""}`,
      HOME: temp,
      USERPROFILE: temp,
      OPENAI_API_KEY: "must-not-be-forwarded",
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
    protocolVersion: "2.3",
    requestId: "i1",
    workerTypeId: "codex",
    adapterVersion: "1.0.0",
  });
  assert.equal(
    (await adapterProcess.waitFor((frame) => frame.requestId === "i1")).type,
    "initialize.result",
  );
  adapterProcess.send({
    type: "probe.request",
    protocolVersion: "2.3",
    mode: "passive",
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
      protocolVersion: "2.5",
      requestId: "v1",
      ready: true,
      toolVersion: "1.2.3",
      mode: "passive",
      checks: [
        { id: "cli_discovery", status: "passed" },
        { id: "tool_version", status: "passed" },
        { id: "authentication", status: "passed" },
      ],
    },
  );
  adapterProcess.send({
    type: "execute.request",
    protocolVersion: "2.3",
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
  const calls = (await readFile(callsFile, "utf8")).trim().split("\n");
  assert.deepEqual(calls.slice(0, 2), ["--version", "login status"]);
  assert.match(args, /--ask-for-approval never/);
  assert.match(args, /--sandbox workspace-write/);
  assert.match(args, /--model gpt-5\.5/);
  assert.ok(args.includes(`--cd ${await realpath(temp)}`));
  await assert.rejects(readFile(childEnvFile, "utf8"));

  adapterProcess.send({
    type: "execute.request",
    protocolVersion: "2.3",
    requestId: "e2",
    assignmentId: "a2",
    prompt: "Use the Codex default model.",
  });
  const resultWithoutModel = await adapterProcess.waitFor(
    (frame) => frame.requestId === "e2" && frame.type === "result",
  );
  assert.equal(resultWithoutModel.type, "result");
  const defaultModelArgs = await readFile(argsFile, "utf8");
  assert.doesNotMatch(defaultModelArgs, /--model/);
});

test("reports a stable authentication reason without exposing CLI output", async (t) => {
  const temp = await mkdtemp(join(tmpdir(), "conclave-codex-auth-"));
  t.after(() => rm(temp, { recursive: true, force: true }));
  const bin = join(temp, "bin");
  await import("node:fs/promises").then(({ mkdir }) => mkdir(bin));
  const fakeCodex = join(bin, "codex");
  await writeFile(
    fakeCodex,
    "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'codex 1.2.3'; exit 0; fi\necho 'private account diagnostic' >&2\nexit 1\n",
  );
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
    type: "probe.request",
    protocolVersion: "2.3",
    mode: "passive",
    requestId: "v2",
  });
  const response = await adapterProcess.waitFor(
    (frame) => frame.requestId === "v2",
  );
  assert.equal(response.type, "probe.result");
  assert.equal(response.ready, false);
  assert.equal(
    response.checks.find((check) => check.status === "failed").issueCode,
    "authentication_required",
  );
  assert.doesNotMatch(JSON.stringify(response), /private account diagnostic/);
});

test("reports a stable missing CLI reason", async (t) => {
  const temp = await mkdtemp(join(tmpdir(), "conclave-codex-missing-"));
  t.after(() => rm(temp, { recursive: true, force: true }));
  const adapterProcess = await startAdapter({
    ...process.env,
    PATH: "",
    HOME: temp,
    USERPROFILE: temp,
  });
  t.after(async () => {
    adapterProcess.child.stdin.end();
    if (adapterProcess.child.exitCode === null)
      adapterProcess.child.kill("SIGKILL");
    await once(adapterProcess.child, "close").catch(() => {});
  });
  adapterProcess.send({
    type: "probe.request",
    protocolVersion: "2.3",
    mode: "passive",
    requestId: "v3",
  });
  const response = await adapterProcess.waitFor(
    (frame) => frame.requestId === "v3",
  );
  assert.equal(response.type, "probe.result");
  assert.equal(response.ready, false);
  assert.equal(
    response.checks.find((check) => check.status === "failed").issueCode,
    "cli_not_found",
  );
});

test("normalizes provider diagnostics to stable, non-sensitive error codes", async (t) => {
  const cases = [
    ["authentication required", "authentication_required"],
    ["model not supported", "model_not_supported"],
    ["usage limit exceeded", "quota_exhausted"],
    ["provider unavailable (503)", "provider_unavailable"],
    ["permission denied by sandbox", "permission_denied"],
    ["opaque private diagnostic", "execution_failed"],
    ["provider unavailable (503)", "provider_unavailable", true],
  ];
  for (const [diagnostic, expectedCode, stderrOnly = false] of cases) {
    const temp = await mkdtemp(join(tmpdir(), "conclave-codex-error-"));
    t.after(() => rm(temp, { recursive: true, force: true }));
    const fakeCodex = join(temp, "codex");
    await writeFile(
      fakeCodex,
      stderrOnly
        ? `#!/bin/sh\ncat >/dev/null\necho '${diagnostic}' >&2\nexit 1\n`
        : `#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{"type":"turn.failed","error":{"message":"${diagnostic}"}}'\nexit 1\n`,
    );
    await chmod(fakeCodex, 0o755);
    const adapterProcess = await startAdapter({
      PATH: `${join(temp)}:${process.env.PATH ?? ""}`,
      HOME: temp,
      TMPDIR: process.env.TMPDIR,
    });
    t.after(async () => {
      adapterProcess.child.stdin.end();
      if (adapterProcess.child.exitCode === null)
        adapterProcess.child.kill("SIGKILL");
      await once(adapterProcess.child, "close").catch(() => {});
    });
    adapterProcess.send({
      type: "execute.request",
      protocolVersion: "2.3",
      requestId: `e-${expectedCode}`,
      assignmentId: "a1",
      prompt: "test",
    });
    const response = await adapterProcess.waitFor(
      (frame) => frame.requestId === `e-${expectedCode}`,
    );
    assert.equal(response.type, "error");
    assert.equal(response.code, expectedCode);
    assert.doesNotMatch(JSON.stringify(response), /opaque private diagnostic/);
  }
});

test(
  "runs opt-in real Codex stateless and durable-session acceptance",
  {
    skip: process.env.CONCLAVE_TEST_REAL_CODEX !== "1",
  },
  async (t) => {
    await runLiveCliAcceptance({
      t,
      startAdapter,
      adapterManifestUrl: new URL("../manifest.template.json", import.meta.url),
      workerTypeId: "codex",
      productName: "ChatGPT",
    });
  },
);
