import { describe, expect, it } from "vitest";
import { executeWithPolicy } from "../src/index.js";
import { request, worker } from "./assignment-fixtures.js";

describe("remote assignment ensemble", () => {
  it("accepts independent worker candidates and synthesizes them", async () => {
    const result = await executeWithPolicy({
      policy: { mode: "synthesize", maxParallel: 2 },
      request,
      workers: [
        worker("chatgpt-web", { independenceKey: "openai-web" }),
        worker("claude-web", { independenceKey: "anthropic-web" }),
      ],
      synthesizer: worker("synthesizer"),
    });
    expect(result.decision?.payload.outcome).toBe("accepted");
  });
});
