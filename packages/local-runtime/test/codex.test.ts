import { mkdtemp } from "node:fs/promises";
import { realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type { WorkerExecutionRequest } from "@conclave/core";
import { describe, expect, it } from "vitest";

import {
  CodexLocalAgent,
  type CodexChild,
  type CodexSpawn,
} from "../src/index.js";

class FakeChild implements CodexChild {
  readonly stdout = new Stream();
  readonly stderr = new Stream();
  readonly pid = 1234;
  private readonly listeners = new Map<string, ((value: never) => void)[]>();

  on(event: "error" | "close", listener: (value: never) => void): void {
    const listeners = this.listeners.get(event) ?? [];
    listeners.push(listener);
    this.listeners.set(event, listeners);
  }

  kill(): void {
    this.close(null);
  }

  emitClose(code: number | null): void {
    this.close(code);
  }

  private close(code: number | null): void {
    for (const listener of this.listeners.get("close") ?? [])
      listener(code as never);
  }
}

class Stream {
  private listener: ((chunk: Buffer) => void) | undefined;
  on(_event: "data", listener: (chunk: Buffer) => void): void {
    this.listener = listener;
  }
  emit(value: string): void {
    this.listener?.(Buffer.from(value));
  }
}

function request(): WorkerExecutionRequest {
  return {
    requestId: "request-1",
    goalId: "goal-1",
    runId: "run-1",
    taskId: "task-1",
    attemptId: "attempt-1",
    workerId: "codex-local",
    connectionId: "desktop-1",
    repositoryId: "repo-1",
    message: { objective: "fix the bug" },
    context: [],
  };
}

async function repository(): Promise<string> {
  return mkdtemp(join(tmpdir(), "conclave-codex-"));
}

describe("CodexLocalAgent", () => {
  it("runs codex in the registered repository and returns its protocol envelope", async () => {
    const root = await repository();
    const child = new FakeChild();
    let command = "";
    let args: readonly string[] = [];
    let cwd = "";
    const spawn: CodexSpawn = (executable, receivedArgs, options) => {
      command = executable;
      args = receivedArgs;
      cwd = options.cwd;
      queueMicrotask(() => {
        child.stdout.emit('{"type":"item"}\n');
        child.stdout.emit(
          '{"messageType":"ImplementationResult","payload":{"summary":"done"}}\n',
        );
        child.emitClose(0);
      });
      return child;
    };
    const agent = new CodexLocalAgent({
      descriptor: {
        workerId: "codex-local",
        connectionId: "desktop-1",
        name: "Codex Local",
        type: "agent",
        roles: ["implementer"],
        capabilities: ["code_generation"],
        permissions: ["repository_read", "repository_write"],
        independenceKey: "codex-local",
        availability: "available",
      },
      repositories: [{ id: "repo-1", root }],
      spawn,
    });

    const result = await agent.execute(request());

    expect(result.status).toBe("succeeded");
    expect(result.output).toBe(
      '{"messageType":"ImplementationResult","payload":{"summary":"done"}}',
    );
    expect(command).toBe("codex");
    expect(args.slice(0, 3)).toEqual(["exec", "--json", "--full-auto"]);
    expect(cwd).toBe(realpathSync(root));
  });

  it("rejects output that is not a Conclave protocol envelope", async () => {
    const root = await repository();
    const child = new FakeChild();
    const spawn: CodexSpawn = (executable, args, options) => {
      void executable;
      void args;
      void options;
      queueMicrotask(() => {
        child.stdout.emit("plain text from codex\n");
        child.emitClose(0);
      });
      return child;
    };
    const agent = new CodexLocalAgent({
      descriptor: {
        workerId: "codex-local",
        connectionId: "desktop-1",
        name: "Codex Local",
        type: "agent",
        roles: ["implementer"],
        capabilities: ["code_generation"],
        permissions: [],
        independenceKey: "codex-local",
        availability: "available",
      },
      repositories: [{ id: "repo-1", root }],
      spawn,
    });

    const result = await agent.execute(request());

    expect(result.status).toBe("failed");
    expect(result.error?.code).toBe("invalid_protocol_output");
  });

  it("does not execute against an unregistered repository", async () => {
    const root = await repository();
    const agent = new CodexLocalAgent({
      descriptor: {
        workerId: "codex-local",
        connectionId: "desktop-1",
        name: "Codex Local",
        type: "agent",
        roles: [],
        capabilities: [],
        permissions: [],
        independenceKey: "codex-local",
        availability: "available",
      },
      repositories: [{ id: "repo-1", root }],
      spawn: (executable, args, options) => {
        void executable;
        void args;
        void options;
        throw new Error("should not spawn");
      },
    });

    const result = await agent.execute({
      ...request(),
      repositoryId: "other-repo",
    });

    expect(result.error?.code).toBe("repository_not_registered");
  });
});
