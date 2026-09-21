import { describe, expect, it } from "vitest";

import type { GoalRecord, RunRecord } from "@conclave/persistence";
import type { WorkerResource } from "@conclave/core";
import type {
  ModelRequest,
  ModelResponse,
  ModelWorker,
} from "@conclave/providers";
import type { ImplementationOperation } from "@conclave/protocol";

import {
  executeForgeGoal,
  InMemoryForgePersistence,
  type ForgeRuntimeAdapter,
} from "../src/index.js";

const goal: GoalRecord = {
  id: "forge-goal",
  projectId: "project-1",
  originalMessage: "Fix the greeting bug",
  objective: "Fix the greeting bug and add a regression test",
  constraints: ["Keep the public API stable"],
  completionCriteria: ["The bug is fixed", "A regression test passes"],
  verificationPolicy: { name: "high" },
  status: "running",
  createdAt: "2026-09-21T10:00:00.000Z",
  updatedAt: "2026-09-21T10:00:00.000Z",
};

const run: RunRecord = {
  id: "forge-run",
  goalId: goal.id,
  parentRunId: null,
  policySnapshot: { verificationPolicy: "high" },
  currentPhaseId: null,
  status: "active",
  startedAt: "2026-09-21T10:00:00.000Z",
  finishedAt: null,
  createdAt: "2026-09-21T10:00:00.000Z",
  updatedAt: "2026-09-21T10:00:00.000Z",
};

function resource(
  id: string,
  roles: readonly string[],
  capabilities: readonly string[],
): WorkerResource {
  return {
    id,
    name: `${id}-model`,
    type: "model",
    provider: id,
    adapterVersion: "1",
    capabilities,
    roles,
    permissions: ["repository_read", "repository_write"],
    availability: "available",
    cost: {
      currency: "USD",
      estimatedCostMicrosPerAttempt: 1,
      inputMicrosPerMillionTokens: 1,
      outputMicrosPerMillionTokens: 1,
    },
    executionEnvironment: "cloud",
  };
}

class FakeWorker implements ModelWorker {
  private cursor = 0;
  readonly requests: ModelRequest[] = [];

  constructor(
    readonly resource: WorkerResource,
    private readonly outputs: readonly string[],
  ) {}

  complete(request: ModelRequest): Promise<ModelResponse> {
    this.requests.push(request);
    const text = this.outputs[this.cursor++];
    if (text === undefined)
      throw new Error(`${this.resource.id} ran out of outputs`);
    return Promise.resolve({
      providerRequestId: `${this.resource.id}-${this.cursor}`,
      text,
      rawResponse: JSON.stringify({ output_text: text }),
      usage: { inputTokens: 10, outputTokens: 20 },
    });
  }
}

function envelope(
  messageType: string,
  workerId: string,
  payload: Record<string, unknown>,
): string {
  return JSON.stringify({
    protocol: "conclave.protocol",
    version: "0.1",
    messageId: `${messageType}-message`,
    goalId: goal.id,
    runId: run.id,
    workerId,
    createdAt: "2026-09-21T10:01:00.000Z",
    messageType,
    payload,
  });
}

const appliedOperations: ImplementationOperation[][] = [];

const runtime: ForgeRuntimeAdapter = {
  async inspect() {
    return {
      operation: "research",
      status: "succeeded",
      summary: "Repository inspected",
      content:
        "src/greeting.ts contains the bug; tests live in test/greeting.test.ts",
      contentDigest: "research-digest",
    };
  },
  async apply(input) {
    appliedOperations.push([...input.operations]);
    return {
      operation: "apply",
      status: "succeeded",
      summary: "Patch applied",
      content: "Applied the implementation and regression test",
      contentDigest: "apply-digest",
    };
  },
  async test() {
    return {
      operation: "test",
      status: "succeeded",
      summary: "Tests passed",
      content: "pnpm test: 42 passed",
      contentDigest: "test-digest",
      command: ["pnpm", "test"],
      exitCode: 0,
    };
  },
};

describe("Forge MVP workflow", () => {
  it("researches, plans, implements, fixes, tests, verifies, and reports", async () => {
    const lead = new FakeWorker(
      resource("lead", ["lead"], ["planning", "evaluation", "repository_read"]),
      [
        envelope("ResearchResult", "lead", {
          summary: "The greeting path has a missing null guard.",
          relevantPaths: ["src/greeting.ts", "test/greeting.test.ts"],
          observations: [
            {
              statement: "Greeting is assembled in src/greeting.ts",
              evidenceArtifactIds: [],
            },
          ],
          risks: ["A regression test is required."],
        }),
        envelope("PlanResult", "lead", {
          phases: [
            {
              phaseId: "plan-phase",
              name: "Fix",
              purpose: "Fix and verify",
              tasks: [
                {
                  taskId: "plan-task",
                  objective: "Fix greeting",
                  role: "Implementer",
                  capabilities: ["repository_write"],
                  dependsOnTaskIds: [],
                  requiresIndependentVerification: true,
                },
              ],
            },
          ],
          assumptions: [],
          risks: [],
        }),
        envelope("VerificationResult", "lead", {
          criterionId: "criterion-1",
          method: "policy_check",
          outcome: "passed",
          evidenceArtifactIds: [],
          rationale: "Review and executable evidence cover the criteria.",
        }),
        envelope("CompletionResult", "lead", {
          outcome: "completed",
          criteria: [
            {
              criterionId: "criterion-1",
              status: "satisfied",
              evidenceArtifactIds: [],
            },
            {
              criterionId: "criterion-2",
              status: "satisfied",
              evidenceArtifactIds: [],
            },
          ],
          finalReportArtifactId: "final-report",
          unresolvedFindingIds: [],
          remainingRisks: [],
        }),
      ],
    );
    const implementer = new FakeWorker(
      resource("implementer", ["implementer"], ["repository_write"]),
      [
        envelope("ImplementationResult", "implementer", {
          status: "succeeded",
          revision: "main",
          changedFiles: ["src/greeting.ts"],
          artifactIds: [],
          proposedOperations: [
            {
              kind: "patch_file",
              path: "src/greeting.ts",
              patches: [
                {
                  oldText: "return greeting",
                  newText: 'return greeting ?? ""',
                },
              ],
            },
          ],
          testsRequested: [],
          summary: "Implemented the null guard.",
          risks: [],
        }),
        envelope("ImplementationResult", "implementer", {
          status: "succeeded",
          revision: "main",
          changedFiles: ["src/greeting.ts", "test/greeting.test.ts"],
          artifactIds: [],
          proposedOperations: [
            {
              kind: "write_file",
              path: "test/greeting.test.ts",
              content: 'test("null greeting", () => {});',
            },
          ],
          testsRequested: ["test/greeting.test.ts"],
          summary: "Added the regression test and fixed the guard.",
          risks: [],
        }),
      ],
    );
    const reviewer = new FakeWorker(
      resource(
        "reviewer",
        ["reviewer", "verifier"],
        ["repository_read", "code_review", "risk_analysis", "test_execution"],
      ),
      [
        envelope("ResearchResult", "reviewer", {
          summary: "The research is directionally correct.",
          relevantPaths: ["src/greeting.ts"],
          observations: [
            {
              statement: "The null guard is the likely fault line.",
              evidenceArtifactIds: [],
            },
          ],
          risks: [],
        }),
        envelope("ReviewResult", "reviewer", {
          outcome: "changes_requested",
          reviewedArtifactIds: [],
          resolvedFindingIds: [],
          findings: [
            {
              findingId: "finding-1",
              severity: "major",
              scope: "tests",
              description: "Add a regression test for the null input.",
              evidenceArtifactIds: [],
            },
          ],
          summary: "The implementation needs regression coverage.",
        }),
        envelope("ReviewResult", "reviewer", {
          outcome: "pass",
          reviewedArtifactIds: [],
          resolvedFindingIds: ["finding-1"],
          findings: [],
          summary: "The correction is complete and independently reviewed.",
        }),
        envelope("TestResult", "reviewer", {
          revision: "main",
          outcome: "pass",
          checks: [
            {
              name: "pnpm test",
              status: "passed",
              command: "pnpm test",
              exitCode: 0,
              artifactIds: [],
            },
          ],
          summary: "All repository tests pass.",
        }),
      ],
    );
    const persistence = new InMemoryForgePersistence();

    const result = await executeForgeGoal({
      goal,
      run,
      repositoryId: "repo-1",
      revision: "main",
      lead,
      implementer,
      reviewer,
      runtime,
      persistence,
      idFactory: (() => {
        let value = 0;
        return () => `forge-${++value}`;
      })(),
      now: () => "2026-09-21T10:00:00.000Z",
    });

    expect(result.completion.payload.outcome).toBe("completed");
    expect(result.secondaryResearch).not.toBeNull();
    expect(result.reviews).toHaveLength(2);
    expect(result.correctionLoops).toBe(1);
    expect(appliedOperations).toHaveLength(2);
    expect(appliedOperations.every((operations) => operations.length > 0)).toBe(
      true,
    );
    expect(persistence.modelCalls).toHaveLength(10);
    expect(persistence.artifacts.length).toBeGreaterThan(15);
    expect(persistence.events.at(-1)?.eventType).toBe("RunCompleted");
    expect(
      new Set(persistence.modelCalls.map((call) => call.workerId)),
    ).toEqual(new Set(["lead", "implementer", "reviewer"]));
    expect(lead.requests[0]?.context?.[0]).toMatchObject({
      mediaType: "text/plain",
      content: expect.stringContaining("src/greeting.ts contains the bug"),
      truncated: false,
      estimatedTokens: expect.any(Number),
    });
    expect(
      reviewer.requests.some((request) =>
        request.context?.some((item) =>
          item.content.includes("pnpm test: 42 passed"),
        ),
      ),
    ).toBe(true);
    expect(
      persistence.artifacts.some(
        (artifact) =>
          artifact.payload.kind === "inline" &&
          artifact.payload.content.includes("src/greeting.ts contains the bug"),
      ),
    ).toBe(true);
  });

  it("rejects a workflow that would let the implementer review itself", async () => {
    const worker = new FakeWorker(
      resource("same", ["lead", "implementer"], ["planning"]),
      [],
    );
    await expect(
      executeForgeGoal({
        goal,
        run,
        repositoryId: "repo-1",
        revision: "main",
        lead: worker,
        implementer: worker,
        runtime,
        persistence: new InMemoryForgePersistence(),
      }),
    ).rejects.toThrow("different from the implementer");
  });
});
