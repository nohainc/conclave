import { spawn } from "node:child_process";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { setTimeout as delay } from "node:timers/promises";
import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";

const providerSessionId = "opaque-provider-session-9f8a";
const contractSecret = "provider-private-detail";

const packages = [
  {
    name: "ChatGPT / Codex Worker Package",
    workerTypeId: "codex",
    packageId: "codex",
    adapter: fileURLToPath(
      new URL("../../codex/bin/conclave-codex-adapter.mjs", import.meta.url),
    ),
    executable: "codex",
    versionOutput: "codex 1.2.3",
    toolVersion: "1.2.3",
    allowlistedEnvironmentName: "CODEX_HOME",
    allowlistedEnvironmentValue: "/contract/codex-home",
    resumeArgument: `resume ${providerSessionId}`,
  },
  {
    name: "Gemini / Antigravity Worker Package",
    workerTypeId: "antigravity",
    packageId: "antigravity",
    adapter: fileURLToPath(
      new URL(
        "../../antigravity/bin/conclave-antigravity-adapter.mjs",
        import.meta.url,
      ),
    ),
    executable: "agy",
    versionOutput: "agy 4.5.6",
    toolVersion: "4.5.6",
    allowlistedEnvironmentName: "GEMINI_API_KEY",
    allowlistedEnvironmentValue: "contract-gemini-key",
    resumeArgument: `--conversation ${providerSessionId}`,
  },
];

function fakeCliScript(config, files) {
  const quote = (value) => `'${value.replaceAll("'", "'\\''")}'`;
  const common = `#!/bin/sh
set -eu
printf '%s\\n' "$*" >> ${quote(files.calls)}
if [ "$1" = "--version" ]; then printf '%s\\n' ${quote(config.versionOutput)}; exit 0; fi
${config.workerTypeId === "codex" ? 'if [ "$1" = "login" ] && [ "$2" = "status" ]; then exit 0; fi' : ""}
prompt=$(cat)
printf '%s\\n%s\\n' "\${${config.allowlistedEnvironmentName}:-}" "\${CONCLAVE_CONTRACT_BLOCKED:-}" > ${quote(files.environment)}
case "$prompt" in
  *CONTRACT_MODE_TIMEOUT*|*CONTRACT_MODE_CANCEL*)
    sleep 30 &
    child=$!
    printf '%s\\n' "$child" > ${quote(files.childPid)}
    wait "$child"
    ;;
  *CONTRACT_MODE_MALFORMED*)
    printf '%s\\n' 'provider-private malformed output' ;;
  *CONTRACT_MODE_ERROR*)
    ${
      config.workerTypeId === "codex"
        ? `printf '%s\\n' '{"type":"turn.failed","error":{"message":"quota exhausted ${contractSecret}"}}'`
        : `printf '%s\\n' '{"event":"result","result":{"status":"ERROR","error":"quota exhausted ${contractSecret}"}}'`
    }
    exit 1
    ;;
  *)
    ${
      config.workerTypeId === "codex"
        ? `
    printf '%s\\n' '{"type":"thread.started","thread_id":"${providerSessionId}"}'
    printf '%s\\n' '{"type":"turn.started"}'
    printf '%s\\n' '{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"${contractSecret}"}}'
    if printf '%s' "$prompt" | grep -q 'exactly the word OK'; then answer=OK; else answer='contract final answer'; fi
    printf '{"type":"item.completed","item":{"type":"agent_message","text":"%s"}}\\n' "$answer"
    printf '%s\\n' '{"type":"turn.completed"}'`
        : `
    printf '%s\\n' '{"event":"init","conversation_id":"${providerSessionId}"}'
    printf '%s\\n' '{"event":"step_update","step_update":{"state":"RUNNING"}}'
    if printf '%s' "$prompt" | grep -q 'exactly the word OK'; then answer=OK; else answer='contract final answer'; fi
    printf '{"event":"result","result":{"status":"SUCCESS","response":"%s","conversation_id":"${providerSessionId}"}}\\n' "$answer"`
    }
    ;;
esac
`;
  return common;
}

async function createHarness(t, config, { workerStateDirectory } = {}) {
  const root = await mkdtemp(join(tmpdir(), "conclave-lwp-contract-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const bin = join(root, "bin");
  await import("node:fs/promises").then(({ mkdir }) => mkdir(bin));
  const files = {
    calls: join(root, "cli-calls.txt"),
    environment: join(root, "cli-environment.txt"),
    childPid: join(root, "provider-child.pid"),
  };
  const executable = join(bin, config.executable);
  await writeFile(executable, fakeCliScript(config, files));
  await chmod(executable, 0o755);
  const env = {
    PATH: `${bin}${process.platform === "win32" ? ";" : ":"}${process.env.PATH ?? ""}`,
    HOME: root,
    USERPROFILE: root,
    CONCLAVE_WORKER_STATE_DIR:
      workerStateDirectory ?? join(root, "worker-state"),
    CONCLAVE_CONTRACT_BLOCKED: "must-not-reach-provider-cli",
    [config.allowlistedEnvironmentName]: config.allowlistedEnvironmentValue,
  };
  const child = spawn(process.execPath, [config.adapter], {
    cwd: root,
    env: { ...process.env, ...env },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const frames = [];
  const parseErrors = [];
  let stderr = "";
  const waiters = [];
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  lines.on("line", (line) => {
    let frame;
    try {
      frame = JSON.parse(line);
      frames.push(frame);
    } catch (error) {
      parseErrors.push({ line, error });
      return;
    }
    for (const waiter of [...waiters]) {
      if (!waiter.predicate(frame)) continue;
      waiters.splice(waiters.indexOf(waiter), 1);
      clearTimeout(waiter.timer);
      waiter.resolve(frame);
    }
  });
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    stderr = `${stderr}${chunk}`.slice(-8192);
  });
  child.on("close", () => {
    for (const waiter of waiters.splice(0)) {
      clearTimeout(waiter.timer);
      waiter.reject(
        new Error(`package exited before response; stderr: ${stderr}`),
      );
    }
  });
  const harness = {
    root,
    workerStateDirectory: env.CONCLAVE_WORKER_STATE_DIR,
    files,
    child,
    frames,
    parseErrors,
    get stderr() {
      return stderr;
    },
    send(frame) {
      child.stdin.write(`${JSON.stringify(frame)}\n`);
    },
    waitFor(predicate, timeoutMs = 5000) {
      const existing = frames.find(predicate);
      if (existing) return Promise.resolve(existing);
      return new Promise((resolve, reject) => {
        const waiter = { predicate, resolve, reject, timer: null };
        waiter.timer = setTimeout(() => {
          waiters.splice(waiters.indexOf(waiter), 1);
          let calls = "unavailable";
          let childPid = "unavailable";
          try {
            calls = readFileSync(join(root, "cli-calls.txt"), "utf8");
          } catch {}
          try {
            childPid = readFileSync(join(root, "provider-child.pid"), "utf8");
          } catch {}
          reject(
            new Error(
              `timed out waiting for package frame; root=${root}; calls=${JSON.stringify(calls)}; providerChild=${childPid}; frames=${JSON.stringify(frames)}; stderr: ${stderr}`,
            ),
          );
        }, timeoutMs);
        waiters.push(waiter);
      });
    },
    async close() {
      if (child.exitCode !== null || child.signalCode !== null) return;
      child.stdin.end();
      await waitForClose(child);
    },
  };
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null)
      child.kill("SIGKILL");
    await waitForClose(child).catch(() => {});
  });
  return harness;
}

function waitForClose(child, timeoutMs = 5000) {
  if (child.exitCode !== null || child.signalCode !== null)
    return Promise.resolve();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error("package did not exit")),
      timeoutMs,
    );
    child.once("close", () => {
      clearTimeout(timer);
      resolve();
    });
  });
}

function initialize(harness, config, requestId = "init-1") {
  harness.send({
    type: "initialize.request",
    protocolVersion: "2.5",
    requestId,
    workerTypeId: config.workerTypeId,
    adapterVersion: "1.0.0",
  });
  return harness.waitFor((frame) => frame.requestId === requestId);
}

function probe(harness, requestId, mode) {
  harness.send({
    type: "probe.request",
    protocolVersion: "2.5",
    requestId,
    mode,
  });
  return harness.waitFor((frame) => frame.requestId === requestId);
}

function execute(harness, requestId, assignmentId, prompt, options = {}) {
  const { waitTimeoutMs = 5000, ...protocolOptions } = options;
  harness.send({
    type: "execute.request",
    protocolVersion: "2.5",
    requestId,
    assignmentId,
    prompt,
    ...protocolOptions,
  });
  return harness.waitFor(
    (frame) =>
      frame.requestId === requestId && ["result", "error"].includes(frame.type),
    waitTimeoutMs,
  );
}

async function assertProviderProcessGone(pid) {
  const processId = Number(pid);
  assert.ok(Number.isInteger(processId) && processId > 0);
  for (let attempt = 0; attempt < 40; attempt++) {
    try {
      process.kill(processId, 0);
      await delay(50);
    } catch (error) {
      if (error.code === "ESRCH") return;
      throw error;
    }
  }
  assert.fail(`provider child ${processId} remained after package cleanup`);
}

for (const config of packages) {
  test(`${config.name} implements the Local Worker Protocol contract`, async (t) => {
    await t.test(
      "initialize, passive/live probe, progress, and result",
      async (t) => {
        const harness = await createHarness(t, config);
        const initialized = await initialize(harness, config);
        assert.equal(initialized.type, "initialize.result");
        assert.ok(initialized.capabilities.includes("code"));

        const passive = await probe(harness, "probe-passive", "passive");
        assert.equal(passive.type, "probe.result");
        assert.equal(passive.ready, true);
        assert.equal(passive.mode, "passive");
        assert.equal(passive.toolVersion, config.toolVersion);
        assert.ok(
          passive.checks.some(
            (check) =>
              check.id === "cli_discovery" && check.status === "passed",
          ),
        );
        assert.ok(
          passive.checks.some(
            (check) => check.id === "tool_version" && check.status === "passed",
          ),
        );
        const passiveCalls = await readFile(harness.files.calls, "utf8");
        assert.doesNotMatch(passiveCalls, /--json|--input-format/);

        const live = await probe(harness, "probe-live", "live");
        assert.equal(live.type, "probe.result");
        assert.equal(live.ready, true);
        assert.equal(live.mode, "live");
        assert.ok(
          live.checks.some(
            (check) => check.id === "execution" && check.status === "passed",
          ),
        );

        const progressWaiter = harness.waitFor(
          (frame) =>
            frame.type === "progress" && frame.requestId === "execute-1",
        );
        const resultWaiter = execute(
          harness,
          "execute-1",
          "assignment-1",
          "Make a small change.",
        );
        const [progress, result] = await Promise.all([
          progressWaiter,
          resultWaiter,
        ]);
        assert.equal(progress.assignmentId, "assignment-1");
        assert.equal(result.type, "result");
        assert.equal(result.assignmentId, "assignment-1");
        assert.equal(result.output, "contract final answer");
        assert.deepEqual(result.artifacts, []);
        assert.doesNotMatch(progress.message, /${contractSecret}/);
      },
    );

    await t.test(
      "keeps package environment allowlisting at the CLI boundary",
      async (t) => {
        const harness = await createHarness(t, config);
        const result = await execute(
          harness,
          "env-run",
          "env-assignment",
          "Check your environment.",
        );
        assert.equal(result.type, "result");
        const [allowed, blocked] = (
          await readFile(harness.files.environment, "utf8")
        )
          .trim()
          .split("\n");
        assert.equal(allowed, config.allowlistedEnvironmentValue);
        assert.equal(blocked ?? "", "");
      },
    );

    await t.test(
      "maps provider errors to stable safe protocol errors",
      async (t) => {
        const harness = await createHarness(t, config);
        const response = await execute(
          harness,
          "error-run",
          "error-assignment",
          "CONTRACT_MODE_ERROR",
        );
        assert.equal(response.type, "error");
        assert.equal(response.code, "quota_exhausted");
        assert.equal(response.requestId, "error-run");
        assert.equal(response.assignmentId, "error-assignment");
        assert.equal(response.retryable, false);
        assert.doesNotMatch(
          JSON.stringify(response),
          new RegExp(contractSecret),
        );
      },
    );

    await t.test(
      "returns a timeout error and cleans up timed-out CLI children",
      async (t) => {
        const harness = await createHarness(t, config);
        const response = await execute(
          harness,
          "timeout-run",
          "timeout-assignment",
          "CONTRACT_MODE_TIMEOUT",
          { timeoutMs: 2200, waitTimeoutMs: 4000 },
        );
        assert.equal(response.type, "error");
        assert.equal(response.code, "timeout");
        await assertProviderProcessGone(
          await readFile(harness.files.childPid, "utf8"),
        );
      },
    );

    await t.test("normalizes malformed provider CLI output", async (t) => {
      const harness = await createHarness(t, config);
      const response = await execute(
        harness,
        "malformed-run",
        "malformed-assignment",
        "CONTRACT_MODE_MALFORMED",
      );
      assert.equal(response.type, "error");
      assert.equal(response.code, "execution_failed");
      assert.doesNotMatch(
        JSON.stringify(response),
        /provider-private malformed output/,
      );
    });

    await t.test(
      "terminates the provider process tree when the package is cancelled",
      async (t) => {
        if (process.platform === "win32")
          return t.skip("fake CLI process-tree fixture uses POSIX shell");
        const harness = await createHarness(t, config);
        const responseWaiter = execute(
          harness,
          "cancel-run",
          "cancel-assignment",
          "CONTRACT_MODE_CANCEL",
          { timeoutMs: 10000, waitTimeoutMs: 4000 },
        ).catch(() => null);
        for (let attempt = 0; attempt < 100; attempt++) {
          try {
            await readFile(harness.files.childPid, "utf8");
            break;
          } catch {
            await delay(20);
          }
        }
        const childPid = await readFile(harness.files.childPid, "utf8");
        harness.child.kill("SIGTERM");
        await waitForClose(harness.child, 4000);
        const response = await responseWaiter;
        if (response) {
          assert.equal(response.type, "error");
          assert.equal(response.code, "cancelled");
        }
        await assertProviderProcessGone(childPid);
      },
    );

    await t.test(
      "starts and resumes a durable local session using an opaque key",
      async (t) => {
        const firstPackage = await createHarness(t, config);
        const sessionOptions = {
          sessionPolicy: "durable_session",
          sessionKey: "conclave-session-key",
        };
        const first = await execute(
          firstPackage,
          "session-start",
          "session-assignment-1",
          "Start a durable session.",
          sessionOptions,
        );
        assert.equal(first.type, "result");
        await firstPackage.close();

        const resumedPackage = await createHarness(t, config, {
          workerStateDirectory: firstPackage.workerStateDirectory,
        });
        const second = await execute(
          resumedPackage,
          "session-resume",
          "session-assignment-2",
          "Continue the same durable session.",
          sessionOptions,
        );
        assert.equal(second.type, "result");
        const calls = await readFile(resumedPackage.files.calls, "utf8");
        assert.ok(calls.includes(config.resumeArgument));
        assert.doesNotMatch(
          JSON.stringify([...firstPackage.frames, ...resumedPackage.frames]),
          new RegExp(providerSessionId),
        );
        assert.ok(
          firstPackage.frames.some(
            (frame) =>
              frame.requestId === "session-start" && frame.type === "progress",
          ),
        );
        assert.equal(second.output, "contract final answer");
      },
    );
  });
}
