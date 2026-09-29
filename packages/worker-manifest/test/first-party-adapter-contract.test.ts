import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { afterEach, describe, expect, it } from "vitest";
import {
  V7_ADAPTER_PROTOCOL_VERSION,
  parseV7AdapterFrame,
  serializeV7AdapterFrame,
} from "../src/adapter-v7.js";

const cases = [
  {
    name: "ChatGPT through Codex",
    workerTypeId: "codex",
    executable: "codex",
    version: "1.2.3",
    adapter: new URL(
      "../adapters/codex/bin/conclave-codex-adapter.mjs",
      import.meta.url,
    ),
    script: `#!/bin/sh
if [ "$1" = "--version" ]; then echo 'codex 1.2.3'; exit 0; fi
if [ "$1" = "login" ]; then exit 0; fi
cat >/dev/null
printf '%s\\n' '{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"private fixture data"}}'
printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Codex contract result"}}'
printf '%s\\n' '{"type":"turn.completed"}'
`,
  },
  {
    name: "Gemini through Antigravity",
    workerTypeId: "antigravity",
    executable: "agy",
    version: "4.5.6",
    adapter: new URL(
      "../adapters/antigravity/bin/conclave-antigravity-adapter.mjs",
      import.meta.url,
    ),
    script: `#!/bin/sh
if [ "$1" = "--version" ]; then echo 'agy 4.5.6'; exit 0; fi
if [ "$1" = "-p" ] && [ "$2" = "/usage" ]; then exit 0; fi
cat >/dev/null
printf '%s\\n' '{"event":"step_update","step_update":{"state":"RUNNING"}}'
printf '%s\\n' '{"event":"result","result":{"status":"SUCCESS","response":"Gemini contract result"}}'
`,
  },
] as const;

describe.each(cases)("$name Local Adapter Protocol contract", (adapterCase) => {
  let directory: string | undefined;
  let processHandle: ReturnType<typeof spawn> | undefined;

  afterEach(async () => {
    processHandle?.stdin?.end();
    if (processHandle && processHandle.exitCode === null) {
      processHandle.kill("SIGKILL");
    }
    if (directory) await rm(directory, { recursive: true, force: true });
  });

  it("uses the same strict, correlated initialize/probe/execute frames", async () => {
    directory = await mkdtemp(join(tmpdir(), "conclave-protocol-contract-"));
    const bin = join(directory, "bin");
    await import("node:fs/promises").then(({ mkdir }) => mkdir(bin));
    const fakeCli = join(bin, adapterCase.executable);
    await writeFile(fakeCli, adapterCase.script);
    await chmod(fakeCli, 0o755);

    processHandle = spawn(
      process.execPath,
      [new URL(adapterCase.adapter).pathname],
      {
        env: {
          ...process.env,
          PATH: `${bin}:${process.env.PATH ?? ""}`,
          OPENAI_API_KEY: "contract-secret-openai",
          GEMINI_API_KEY: "contract-secret-gemini",
        },
        stdio: ["pipe", "pipe", "pipe"],
      },
    );

    const frames = new Map<string, Record<string, unknown>>();
    const waiters: Array<{
      predicate: (frame: Record<string, unknown>) => boolean;
      resolve: (frame: Record<string, unknown>) => void;
    }> = [];
    let stderrOutput = "";
    processHandle.stderr?.on("data", (chunk) => {
      stderrOutput += chunk.toString("utf8");
    });
    const lines = createInterface({
      input: processHandle.stdout!,
      crlfDelay: Infinity,
    });
    lines.on("line", (line) => {
      const parsed = parseV7AdapterFrame(line) as Record<string, unknown>;
      expect(parsed.requestId).toEqual(expect.any(String));
      frames.set(`${parsed.type}:${parsed.requestId}`, parsed);
      for (const waiter of [...waiters]) {
        if (waiter.predicate(parsed)) {
          waiters.splice(waiters.indexOf(waiter), 1);
          waiter.resolve(parsed);
        }
      }
    });
    const waitFor = (
      predicate: (frame: Record<string, unknown>) => boolean,
    ) => {
      const existing = [...frames.values()].find(predicate);
      if (existing) return Promise.resolve(existing);
      return new Promise<Record<string, unknown>>((resolve, reject) => {
        const timer = setTimeout(
          () =>
            reject(
              new Error(
                `adapter frame timeout; frames=${JSON.stringify([...frames.values()])}; stderr=${stderrOutput}`,
              ),
            ),
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
    };
    const send = (frame: Parameters<typeof serializeV7AdapterFrame>[0]) => {
      processHandle!.stdin!.write(`${serializeV7AdapterFrame(frame)}\n`);
    };

    send({
      type: "initialize.request",
      protocolVersion: V7_ADAPTER_PROTOCOL_VERSION,
      requestId: "contract-initialize",
      workerTypeId: adapterCase.workerTypeId,
      adapterVersion: "1.0.0",
    });
    const initialized = await waitFor(
      (frame) => frame.requestId === "contract-initialize",
    );
    expect(initialized).toMatchObject({
      type: "initialize.result",
      protocolVersion: V7_ADAPTER_PROTOCOL_VERSION,
      requestId: "contract-initialize",
      adapterVersion: "1.0.0",
    });

    send({
      type: "probe.request",
      protocolVersion: V7_ADAPTER_PROTOCOL_VERSION,
      requestId: "contract-probe",
    });
    const probed = await waitFor(
      (frame) => frame.requestId === "contract-probe",
    );
    expect(probed).toEqual({
      type: "probe.result",
      protocolVersion: V7_ADAPTER_PROTOCOL_VERSION,
      requestId: "contract-probe",
      ready: true,
      toolVersion: adapterCase.version,
      checkKind: "readiness",
      issues: [],
    });

    send({
      type: "execute.request",
      protocolVersion: V7_ADAPTER_PROTOCOL_VERSION,
      requestId: "contract-execute",
      assignmentId: "contract-assignment",
      prompt: "Return a short result.",
    });
    await waitFor(
      (frame) =>
        frame.type === "progress" && frame.requestId === "contract-execute",
    );
    const result = await waitFor(
      (frame) =>
        frame.type === "result" && frame.requestId === "contract-execute",
    );
    expect(result).toMatchObject({
      assignmentId: "contract-assignment",
      output: `${adapterCase.workerTypeId === "codex" ? "Codex" : "Gemini"} contract result`,
    });
    expect(JSON.stringify([...frames.values()])).not.toContain(
      "contract-secret-",
    );
  }, 15_000);
});
