import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  describeRuntimeGoal,
  LocalRuntime,
  OutboundRuntimeSession,
  parseRuntimeOperation,
  type RuntimeEvidence,
  type RuntimeOperation,
  type RuntimeTransport,
  loadRuntimeConfig,
} from "../src/index.js";

const temporaryRoots: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryRoots
      .splice(0)
      .map((root) => rm(root, { recursive: true, force: true })),
  );
});

async function makeRoot(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "conclave-runtime-"));
  temporaryRoots.push(root);
  await writeFile(join(root, "README.md"), "Conclave local runtime\n", "utf8");
  await writeFile(join(root, "config.txt"), "mode=development\n", "utf8");
  return root;
}

function approval(...operationKinds: RuntimeOperation["kind"][]) {
  return {
    approvalId: "approval-1",
    operationKinds,
    expiresAt: new Date(Date.now() + 60_000).toISOString(),
  };
}

function runtime(root: string): LocalRuntime {
  return new LocalRuntime({
    repositories: [{ id: "repo-1", root }],
    allowedCommands: { shell: ["node"], check: ["node"], build: ["node"] },
  });
}

describe("Local Runtime foundation", () => {
  it("loads safe development defaults", () => {
    expect(loadRuntimeConfig({}).apiBaseUrl.href).toBe(
      "http://localhost:8787/",
    );
  });

  it("formats a goal summary for runtime logs", () => {
    expect(
      describeRuntimeGoal({
        id: "goal-1",
        objective: "Ship it",
        status: "ready",
      }),
    ).toContain("goal-1");
  });

  it("reads, searches, and writes only inside an approved repository", async () => {
    const root = await makeRoot();
    const local = runtime(root);
    const base = { requestId: "request-1", repositoryId: "repo-1" };

    const read = await local.execute({
      ...base,
      kind: "read_file",
      path: "README.md",
      approval: approval("read_file"),
    });
    expect(read.status).toBe("succeeded");
    expect(read.content).toContain("local runtime");
    expect(read.contentDigest).toHaveLength(64);

    const search = await local.execute({
      ...base,
      requestId: "request-2",
      kind: "search",
      query: "development",
      approval: approval("search"),
    });
    expect(search.content).toContain("config.txt:1");

    const write = await local.execute({
      ...base,
      requestId: "request-3",
      kind: "write_file",
      path: "notes.txt",
      content: "approved write\n",
      approval: approval("write_file"),
    });
    expect(write.status).toBe("succeeded");
    expect(await readFile(join(root, "notes.txt"), "utf8")).toBe(
      "approved write\n",
    );

    const escape = await local.execute({
      ...base,
      requestId: "request-4",
      kind: "read_file",
      path: "../outside.txt",
      approval: approval("read_file"),
    });
    expect(escape.status).toBe("rejected");
    expect(escape.summary).toContain("escapes");
  });

  it("runs allowlisted commands without invoking a shell", async () => {
    const root = await makeRoot();
    const local = runtime(root);
    const result = await local.execute({
      requestId: "command-1",
      repositoryId: "repo-1",
      kind: "check",
      command: ["node", "-e", "process.stdout.write('check passed')"],
      approval: approval("check"),
    });
    expect(result.status).toBe("succeeded");
    expect(result.exitCode).toBe(0);
    expect(result.content).toBe("check passed");

    const rejected = await local.execute({
      requestId: "command-2",
      repositoryId: "repo-1",
      kind: "shell",
      command: ["sh", "-c", "echo unsafe"],
      approval: approval("shell"),
    });
    expect(rejected.status).toBe("rejected");
    expect(rejected.summary).toContain("not allowed");
  });

  it("rejects expired or incomplete approvals at the runtime boundary", async () => {
    const root = await makeRoot();
    const local = runtime(root);
    const result = await local.execute({
      requestId: "approval-1",
      repositoryId: "repo-1",
      kind: "write_file",
      path: "blocked.txt",
      content: "nope",
      approval: {
        approvalId: "expired",
        operationKinds: ["read_file"],
        expiresAt: new Date(Date.now() - 1).toISOString(),
      },
    });
    expect(result.status).toBe("rejected");
    expect(result.summary).toContain("not covered");

    expect(() =>
      parseRuntimeOperation({ kind: "shell", command: "node" }),
    ).toThrow("requestId is invalid");
  });

  it("connects outbound and returns structured evidence for each request", async () => {
    const root = await makeRoot();
    const request: RuntimeOperation = {
      requestId: "transport-1",
      repositoryId: "repo-1",
      kind: "read_file",
      path: "README.md",
      approval: approval("read_file"),
    };
    const received: RuntimeEvidence[] = [];
    const transport: RuntimeTransport = {
      async connect() {},
      async *receive() {
        yield request;
      },
      async send(evidence) {
        received.push(evidence);
      },
    };
    await new OutboundRuntimeSession(runtime(root), transport).run();
    expect(received).toHaveLength(1);
    expect(received[0]?.requestId).toBe("transport-1");
    expect(received[0]?.audit.actor).toBe("local-runtime");
  });
});
