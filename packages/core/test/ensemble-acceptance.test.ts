import { describe, expect, it } from "vitest";
import {
  executeParallelImplementations,
  executeReadOnlyPanel,
  executeWithFallback,
  executeWithPolicy,
  resolveQuality,
} from "../src/index.js";
import { request, worker } from "./assignment-fixtures.js";

describe("assignment ensemble acceptance", () => {
  it("supports a one-worker policy", async () => {
    const result = await executeWithPolicy({
      policy: { mode: "single" },
      request,
      workers: [worker("lead")],
    });
    expect(result.candidateResults).toHaveLength(1);
  });
  it("runs independent read-only roles", async () => {
    const result = await executeReadOnlyPanel({
      request,
      roles: ["researcher", "architect", "reviewer"],
      workers: {
        researcher: worker("researcher", { roles: ["researcher"] }),
        architect: worker("architect", { roles: ["architect"] }),
        reviewer: worker("reviewer", { roles: ["reviewer"] }),
      },
    });
    expect(result).toHaveLength(3);
  });
  it("supports high-assurance synthesis", async () => {
    const result = await executeWithPolicy({
      policy: resolveQuality("high_assurance").config,
      request,
      workers: [worker("candidate-a"), worker("candidate-b")],
      synthesizer: worker("synthesizer"),
    });
    expect(result.decision?.payload.outcome).toBe("accepted");
  });
  it("isolates parallel implementation workspaces", async () => {
    const result = await executeParallelImplementations({
      request,
      executions: [
        { worker: worker("codex"), workspaceRepositoryId: "repo::codex" },
        { worker: worker("api"), workspaceRepositoryId: "repo::api" },
      ],
    });
    expect(result.map((item) => item.workspaceRepositoryId)).toEqual([
      "repo::codex",
      "repo::api",
    ]);
  });
  it("falls back between assignment workers", async () => {
    const result = await executeWithFallback(request, [
      worker("subscription", { outcome: "failed" }),
      worker("api"),
    ]);
    expect(result.selectedWorkerId).toBe("api");
    expect(result.attempts).toHaveLength(2);
  });
});
