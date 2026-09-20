import { describe, expect, it } from "vitest";
import { describeRuntimeGoal, loadRuntimeConfig } from "../src/index.js";

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
});
