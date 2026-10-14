import { describe, expect, it } from "vitest";
import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { runAcceptance, SUITES } from "./execution-acceptance.mjs";

describe("repeatable execution acceptance runner", () => {
  it("repeats each selected boundary and retains every result", async () => {
    const commands = [];
    const result = await runAcceptance(
      { suites: ["cloud", "service"], repeat: 3 },
      async (suite) => {
        commands.push(suite.command);
        return { exitCode: 0 };
      },
    );
    expect(result.boundaryTestsStatus).toBe("pass");
    expect(result.status).toBe("incomplete");
    expect(result.runs.map((r) => [r.suite, r.iteration])).toEqual([
      ["cloud", 1],
      ["service", 1],
      ["cloud", 2],
      ["service", 2],
      ["cloud", 3],
      ["service", 3],
    ]);
    expect(commands).toHaveLength(6);
    expect(result.liveEvidenceRequired).toHaveLength(3);
  });
  it("a later passing retry cannot hide a failure, missing tool or signal", async () => {
    for (const failure of [
      { exitCode: 1 },
      { exitCode: null, signal: "SIGTERM" },
      { exitCode: null, error: "ENOENT" },
    ]) {
      let calls = 0;
      const result = await runAcceptance(
        { suites: ["cloud"], repeat: 2 },
        async () => (++calls === 1 ? failure : { exitCode: 0 }),
      );
      expect(result.status).toBe("fail");
      expect(result.runs).toHaveLength(2);
    }
  });
  it("validates inputs before executing a command", async () => {
    for (const options of [
      { repeat: 0 },
      { repeat: 26 },
      { suites: [] },
      { suites: ["unknown"] },
      { suites: ["cloud", "cloud"] },
    ])
      await expect(runAcceptance(options)).rejects.toThrow();
  });
  it("references existing focused suites", () => {
    for (const suite of Object.values(SUITES))
      for (const arg of suite.args)
        if (arg.endsWith(".test.ts") || arg.endsWith("_test.dart"))
          expect(existsSync(resolve(suite.cwd, arg)), arg).toBe(true);
  });
});
