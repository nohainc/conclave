import { describe, expect, it } from "vitest";
import { isTerminalGoalStatus } from "../src/index.js";

describe("Core domain foundation", () => {
  it("recognizes terminal goal states", () => {
    expect(isTerminalGoalStatus("completed")).toBe(true);
    expect(isTerminalGoalStatus("running")).toBe(false);
  });
});
