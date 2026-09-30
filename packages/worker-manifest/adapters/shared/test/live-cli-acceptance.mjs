import assert from "node:assert/strict";
import { readFile, mkdtemp, rm } from "node:fs/promises";
import { once } from "node:events";
import { tmpdir } from "node:os";
import { join } from "node:path";

const baseEnvironmentNames = [
  "PATH",
  "HOME",
  "USERPROFILE",
  "TMPDIR",
  "TMP",
  "TEMP",
  "SystemRoot",
  "LANG",
  "LC_ALL",
  "LC_CTYPE",
  "SSL_CERT_FILE",
  "SSL_CERT_DIR",
  "NO_COLOR",
  "TERM",
];

export async function runLiveCliAcceptance({
  t,
  startAdapter,
  adapterManifestUrl,
  workerTypeId,
  productName,
}) {
  const stateDirectory = await mkdtemp(
    join(tmpdir(), `conclave-live-${workerTypeId}-state-`),
  );
  const manifest = JSON.parse(await readFile(adapterManifestUrl, "utf8"));
  const passthrough = manifest.environmentPolicy?.environmentPassthrough ?? [];
  const allowedNames = new Set([
    ...baseEnvironmentNames,
    ...passthrough,
    "CONCLAVE_WORKER_STATE_DIR",
  ]);
  const environment = Object.fromEntries(
    Object.entries(process.env).filter(
      ([name, value]) => allowedNames.has(name) && typeof value === "string",
    ),
  );
  environment.CONCLAVE_WORKER_STATE_DIR = stateDirectory;

  let requestSequence = 0;
  const processes = [];
  t.after(async () => {
    for (const adapter of processes) {
      if (
        adapter.child.exitCode === null &&
        adapter.child.signalCode === null
      ) {
        adapter.child.kill("SIGTERM");
        let timer;
        try {
          await Promise.race([
            once(adapter.child, "close"),
            new Promise((resolve) => {
              timer = setTimeout(resolve, 5000);
            }),
          ]);
        } finally {
          clearTimeout(timer);
        }
        if (
          adapter.child.exitCode === null &&
          adapter.child.signalCode === null
        ) {
          adapter.child.kill("SIGKILL");
          await once(adapter.child, "close").catch(() => {});
        }
      }
    }
    await rm(stateDirectory, { recursive: true, force: true });
  });

  async function executeFreshPackage({
    prompt,
    sessionPolicy,
    sessionKey,
    expectedOutput,
    description,
  }) {
    const adapter = await startAdapter(environment, process.cwd());
    processes.push(adapter);
    const suffix = `${workerTypeId}-${requestSequence++}`;
    const initializeId = `live-init-${suffix}`;
    adapter.send({
      type: "initialize.request",
      protocolVersion: "2.6",
      requestId: initializeId,
      workerTypeId,
      adapterVersion: "1.0.0",
    });
    const initialized = await adapter.waitFor(
      (frame) => frame.requestId === initializeId,
    );
    assert.equal(initialized.type, "initialize.result");

    const probeId = `live-passive-${suffix}`;
    adapter.send({
      type: "probe.request",
      protocolVersion: "2.6",
      requestId: probeId,
      mode: "passive",
    });
    const probed = await adapter.waitFor(
      (frame) => frame.requestId === probeId,
    );
    assert.equal(probed.type, "probe.result");
    assert.equal(probed.ready, true, `${productName} passive probe failed`);
    assert.ok(
      probed.toolVersion,
      `${productName} CLI version was not detected`,
    );

    const requestId = `live-execute-${suffix}`;
    const assignmentId = `live-assignment-${suffix}`;
    adapter.send({
      type: "execute.request",
      protocolVersion: "2.6",
      requestId,
      assignmentId,
      prompt,
      timeoutMs: 120_000,
      sessionPolicy,
      ...(sessionPolicy === "durable_session" ? { sessionKey } : {}),
    });
    const response = await adapter.waitFor(
      (frame) => frame.requestId === requestId,
      180_000,
    );
    assert.equal(
      response.type,
      "result",
      `${productName} ${description} failed with ${response.code ?? response.type}: ${response.message ?? "no result"}`,
    );
    assert.equal(response.assignmentId, assignmentId);
    assert.match(response.output, expectedOutput);
    assert.deepEqual(response.artifacts, []);
    await closeAdapter(adapter);
    return response.output;
  }

  await executeFreshPackage({
    prompt: "Reply with exactly OK. Do not use tools.",
    sessionPolicy: "stateless",
    expectedOutput: /\bOK\b/i,
    description: "stateless real assignment",
  });

  const sessionKey = `local-acceptance-${workerTypeId}-${Date.now()}`;
  await executeFreshPackage({
    prompt:
      "Remember the unique word PINEAPPLE for our next message. Reply with exactly OK.",
    sessionPolicy: "durable_session",
    sessionKey,
    expectedOutput: /\bOK\b/i,
    description: "durable session start",
  });
  await executeFreshPackage({
    prompt:
      "What unique word did I ask you to remember? Reply with only that word.",
    sessionPolicy: "durable_session",
    sessionKey,
    expectedOutput: /\bPINEAPPLE\b/i,
    description: "durable session continuation",
  });
}

async function closeAdapter(adapter) {
  if (adapter.child.exitCode !== null || adapter.child.signalCode !== null)
    return;
  adapter.child.stdin.end();
  let timer;
  try {
    await Promise.race([
      once(adapter.child, "close"),
      new Promise((_, reject) => {
        timer = setTimeout(
          () =>
            reject(new Error("Worker Package did not exit after stdin closed")),
          5000,
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
