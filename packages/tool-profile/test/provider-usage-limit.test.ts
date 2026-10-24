import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  parseToolProfileV1,
  interpretProfileExecution,
  type ProfileExecutionContext,
} from "../src/index.js";

const context: ProfileExecutionContext = {
  prompt: "Continue",
  workingDirectory: "/workspace",
  home: "/home/test",
  workerStateDirectory: "/state",
  assignmentTimeoutMs: 30000,
  executionPolicy: "restricted",
  sessionPolicy: "stateless",
};
function starter(name: string) {
  return parseToolProfileV1(
    readFileSync(
      new URL(
        `../../../apps/profile_lab/assets/profiles/${name}.json`,
        import.meta.url,
      ),
      "utf8",
    ),
  );
}

describe("provider usage limits", () => {
  it.each(["rate_limit", "rate_limit_error", "usage_limit_reached"])(
    "classifies Claude's structured %s without exposing provider output",
    (error) => {
      const result = interpretProfileExecution(starter("claude"), {
        context,
        exitCode: 1,
        stdout: [
          { type: "rate_limit_event", rate_limit_info: { status: "rejected" } },
          {
            type: "assistant",
            error,
            message: {
              content: [
                {
                  type: "text",
                  text: "You've hit your session limit · resets 9:10pm (Europe/Bratislava)",
                },
              ],
            },
          },
          { type: "result", is_error: true, result: "" },
        ]
          .map((value) => JSON.stringify(value))
          .join("\n"),
      });
      expect(result).toMatchObject({
        terminal: "failure",
        issueCode: "quota_exhausted",
        finalText: null,
      });
    },
  );

  for (const name of ["claude", "chatgpt", "gemini", "grok"]) {
    it.each([
      "You've hit your session limit · resets 9:10pm (Europe/Bratislava)",
      "You’ve hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro)",
      "You've hit your limit · resets tomorrow",
      "You've reached your free Grok Build usage limit for now. Get SuperGrok for much higher limits, or try again later…",
      "API error (status 429 Too Many Requests): subscription:free-usage-exhausted: You've used all the included free usage for model grok-4.7 for now. Usage resets over a rolling 24-hour window.",
      "rate_limit_error",
      "usage_limit_reached",
      "insufficient_quota",
      "Your AI credits balance is too low to continue.",
      "RESOURCE_EXHAUSTED (code 429): Resource has been exhausted (e.g. check quota).",
      "You exceeded your current quota",
      "Quota exhausted",
      "Rate limit reached",
    ])(`${name} classifies error-channel evidence: %s`, (stderr) => {
      const result = interpretProfileExecution(starter(name), {
        context,
        stdout: "",
        stderr,
        exitCode: 1,
      });
      expect(result.issueCode).toBe("quota_exhausted");
    });
  }

  it("does not turn a successful answer about limits or an allowed rate-limit notice into an error", () => {
    const result = interpretProfileExecution(starter("claude"), {
      context,
      exitCode: 0,
      stdout: [
        { type: "rate_limit_event", rate_limit_info: { status: "allowed" } },
        {
          type: "result",
          is_error: false,
          result: "You've hit your session limit is an example error.",
        },
      ]
        .map((value) => JSON.stringify(value))
        .join("\n"),
    });
    expect(result.terminal).toBe("success");
    expect(result.issueCode).toBeNull();
  });
});
