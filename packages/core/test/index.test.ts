import { describe, expect, it } from "vitest";
import { admitModelResult, isTerminalGoalStatus } from "../src/index.js";

describe("Core domain foundation", () => {
  it("recognizes terminal goal states", () => {
    expect(isTerminalGoalStatus("completed")).toBe(true);
    expect(isTerminalGoalStatus("running")).toBe(false);
  });

  it("rejects malformed model output at the Core admission boundary", () => {
    expect(() =>
      admitModelResult({ messageType: "CompletionResult" }),
    ).toThrow();
  });
});
