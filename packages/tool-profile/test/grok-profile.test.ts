import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import {
  parseToolProfileV1,
  expandExecutionArguments,
  interpretProfileExecution,
  type ProfileExecutionContext,
} from "../src/index.js";

const profile = parseToolProfileV1(
  readFileSync(
    new URL(
      "../../../apps/profile_lab/assets/profiles/grok.json",
      import.meta.url,
    ),
    "utf8",
  ),
);
const context: ProfileExecutionContext = {
  prompt: "Reply OK",
  workingDirectory: "/work",
  home: "/home/test",
  workerStateDirectory: "/state",
  assignmentTimeoutMs: 30000,
  executionPolicy: "restricted",
  sessionPolicy: "durable",
  model: "grok-4.7",
  reasoningEffort: "high",
};
it("expands Grok model, effort and resume with bounded workspace permissions", () => {
  const args = expandExecutionArguments(profile, {
    ...context,
    sessionId: "session-1",
  });
  expect(args).toEqual(
    expect.arrayContaining([
      "--sandbox",
      "workspace",
      "--permission-mode",
      "dontAsk",
      "--reasoning-effort",
      "high",
      "--resume",
      "session-1",
      "--model",
      "grok-4.7",
    ]),
  );
  expect(
    expandExecutionArguments(profile, {
      ...context,
      executionPolicy: "provider_default",
    }),
  ).toContain("read-only");
});
it("sends the prompt on stdin instead of argv", () => {
  const args = expandExecutionArguments(profile, context);
  expect(args.slice(-2)).toEqual(["-p", "-"]);
  expect(args).not.toContain("Reply OK");
  expect(args).toEqual(
    expect.arrayContaining(["--output-format", "streaming-json"]),
  );
  expect(profile.session.executionPolicyBound).toBe(true);
  expect(profile.activity?.adapter).toBe("grok-streaming-json");
});
it("answers with the streamed text after the last tool call", () => {
  const stdout = readFileSync(
    new URL(
      "../../../engines/cli_worker/test/fixtures/grok-streaming-tools-1.0.67.jsonl",
      import.meta.url,
    ),
    "utf8",
  );
  expect(
    interpretProfileExecution(profile, { context, stdout, exitCode: 0 }),
  ).toMatchObject({
    terminal: "success",
    finalText: "hello",
    sessionId: "01a16ab7-c68a-72d2-90da-bdbbfc983ea4",
  });
});
it("fails on the provider error event instead of accepting it as a reply", () => {
  expect(
    interpretProfileExecution(profile, {
      context,
      stdout: JSON.stringify({
        type: "error",
        message: "Couldn't set model 'nope': Invalid params",
      }),
      exitCode: 1,
    }).terminal,
  ).toBe("failure");
});
