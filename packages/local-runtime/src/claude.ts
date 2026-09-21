import type { LocalWorkerExecutor } from "./index.js";
import { CodexLocalAgent, type CodexLocalAgentOptions } from "./codex.js";

export type ClaudeCodeLocalAgentOptions = Omit<
  CodexLocalAgentOptions,
  "executable" | "args"
> & {
  readonly executable?: string;
  readonly args?: readonly string[];
};

/** Subscription-backed Claude Code worker using the common local-agent contract. */
export class ClaudeCodeLocalAgent
  extends CodexLocalAgent
  implements LocalWorkerExecutor
{
  constructor(options: ClaudeCodeLocalAgentOptions) {
    super({
      ...options,
      executable: options.executable ?? "claude",
      args: options.args ?? ["-p", "--output-format", "json"],
    });
  }
}
