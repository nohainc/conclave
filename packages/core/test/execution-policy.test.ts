import { describe, expect, it } from "vitest";
import { executeWithPolicy } from "../src/index.js";
import { request, worker } from "./assignment-fixtures.js";

describe("assignment execution policy", () => {
  it("runs one assignment", async () => {
    const result = await executeWithPolicy({
      policy: { mode: "single" },
      request,
      workers: [worker("one")],
    });
    expect(result.candidateResults[0]?.status).toBe("completed");
  });
  it("runs independent assignments in parallel", async () => {
    const result = await executeWithPolicy({
      policy: { mode: "parallel", maxParallel: 2 },
      request,
      workers: [worker("one"), worker("two")],
    });
    expect(result.candidateResults).toHaveLength(2);
  });
  it("uses an ordinary assignment for synthesis", async () => {
    const result = await executeWithPolicy({
      policy: { mode: "synthesize" },
      request,
      workers: [worker("one"), worker("two")],
      synthesizer: worker("synthesizer"),
    });
    expect(result.decision?.payload.outcome).toBe("accepted");
  });
});
