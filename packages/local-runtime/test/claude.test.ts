import { mkdtemp } from "node:fs/promises";
import { realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type { WorkerExecutionRequest } from "@conclave/core";
import { describe, expect, it } from "vitest";

import {
  ClaudeCodeLocalAgent,
  type CodexChild,
  type CodexSpawn,
} from "../src/index.js";

class FakeStream {
  private listener: ((chunk: Buffer) => void) | undefined;
  on(_event: "data", listener: (chunk: Buffer) => void): void {
    this.listener = listener;
  }
  emit(value: string): void {
    this.listener?.(Buffer.from(value));
  }
}

class FakeChild implements CodexChild {
  readonly stdout = new FakeStream();
  readonly stderr = new FakeStream();
  readonly pid = 5678;
  private closeListener: ((code: number | null) => void) | undefined;
  on(event: "error" | "close", listener: (value: never) => void): void {
    if (event === "close") {
      this.closeListener = listener as (code: number | null) => void;
    }
  }
  kill(): void {
    this.closeListener?.(null);
  }
  close(code: number): void {
    this.closeListener?.(code);
  }
}

const request = (repositoryId = "repo-1"): WorkerExecutionRequest => ({
  requestId: "claude-request-1",
  goalId: "goal-1",
  runId: "run-1",
  taskId: "task-1",
  attemptId: "attempt-1",
  workerId: "claude-local",
  connectionId: "desktop-1",
  repositoryId,
  message: { objective: "review the implementation" },
  context: [],
});

describe("ClaudeCodeLocalAgent", () => {
  it("uses Claude print mode and unwraps its structured result", async () => {
    const root = await mkdtemp(join(tmpdir(), "conclave-claude-"));
    const child = new FakeChild();
    let executable = "";
    let args: readonly string[] = [];
    let cwd = "";
    const spawn: CodexSpawn = (receivedExecutable, receivedArgs, options) => {
      executable = receivedExecutable;
      args = receivedArgs;
      cwd = options.cwd;
      queueMicrotask(() => {
        child.stdout.emit(
          '{"type":"result","result":"{\\"messageType\\":\\"ReviewResult\\",\\"payload\\":{\\"summary\\":\\"approved\\"}}"}\n',
        );
        child.close(0);
      });
      return child;
    };
    const agent = new ClaudeCodeLocalAgent({
      descriptor: {
        workerId: "claude-local",
        connectionId: "desktop-1",
        name: "Claude Code Local",
        type: "agent",
        roles: ["reviewer"],
        capabilities: ["code_review"],
        permissions: ["repository_read"],
        independenceKey: "claude-local",
        availability: "available",
      },
      repositories: [{ id: "repo-1", root }],
      spawn,
    });

    const result = await agent.execute(request());

    expect(result.status).toBe("succeeded");
    expect(result.output).toBe(
      '{"messageType":"ReviewResult","payload":{"summary":"approved"}}',
    );
    expect(executable).toBe("claude");
    expect(args.slice(0, 3)).toEqual(["-p", "--output-format", "json"]);
    expect(cwd).toBe(realpathSync(root));
  });
});
