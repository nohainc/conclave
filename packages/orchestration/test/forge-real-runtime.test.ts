import { cp, mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import type { WorkerResource } from "@conclave/core";
import { LocalRuntime, type RuntimeOperation } from "@conclave/local-runtime";
import type { GoalRecord, RunRecord } from "@conclave/persistence";
import type {
  ModelRequest,
  ModelResponse,
  ModelWorker,
} from "@conclave/providers";
import {
  executeForgeGoal,
  InMemoryForgePersistence,
  type ForgeRuntimeAdapter,
} from "../src/index.js";

const fixture = new URL("../../../e2e/conclave-e2e-fixture/", import.meta.url);

const goal: GoalRecord = {
  id: "conclave-e2e-goal",
  projectId: "conclave-e2e-project",
  originalMessage:
    "Fix add(), add a regression test, and verify the implementation.",
  objective: "Fix add(), add a regression test, and verify the implementation.",
  constraints: ["Keep the public API stable."],
  completionCriteria: [
    {
      id: "criterion-add-fixed",
      description: "add(a, b) returns the sum of a and b.",
      verificationRequirement: "independent_review",
      status: "pending",
      evidenceArtifactIds: [],
      verifiedByWorkerId: null,
      verificationId: null,
      createdAt: "2026-09-21T10:00:00.000Z",
      updatedAt: "2026-09-21T10:00:00.000Z",
    },
    {
      id: "criterion-regression-test",
      description: "A regression test covers add(2, 3) === 5 and passes.",
      verificationRequirement: "executable_check",
      status: "pending",
      evidenceArtifactIds: [],
      verifiedByWorkerId: null,
      verificationId: null,
      createdAt: "2026-09-21T10:00:00.000Z",
      updatedAt: "2026-09-21T10:00:00.000Z",
    },
  ],
  verificationPolicy: { name: "high" },
  status: "running",
  createdAt: "2026-09-21T10:00:00.000Z",
  updatedAt: "2026-09-21T10:00:00.000Z",
};

const run: RunRecord = {
  id: "conclave-e2e-run",
  goalId: goal.id,
  workflowInstanceId: null,
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
    name: `${id}-worker`,
    type: "model",
    provider: id,
    adapterVersion: "e2e-1",
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

function envelope(
  request: ModelRequest,
  workerId: string,
  messageType: string,
  payload: Record<string, unknown>,
): string {
  const requestPayload = request.message.payload as Record<string, unknown>;
  return JSON.stringify({
    protocol: "conclave.protocol",
    version: "0.1",
    messageId: `${workerId}-${messageType}-${String(requestPayload.taskId)}`,
    goalId: request.message.goalId,
    runId: request.message.runId,
    workerId,
    createdAt: "2026-09-21T10:01:00.000Z",
    messageType,
    payload: {
      ...payload,
      ...(typeof requestPayload.taskId === "string"
        ? { taskId: requestPayload.taskId }
        : {}),
    },
  });
}

class ScenarioModel implements ModelWorker {
  readonly requests: ModelRequest[] = [];

  constructor(readonly resource: WorkerResource) {}

  async complete(request: ModelRequest): Promise<ModelResponse> {
    this.requests.push(request);
    const task = request.message.payload as Record<string, unknown>;
    const objective = String(task.objective ?? "");
    const role = String(task.role ?? "");
    const requestedType = request.message.messageType;
    let messageType: string;
    let payload: Record<string, unknown>;

    if (this.resource.id === "lead" && role === "Researcher") {
      messageType = "ResearchResult";
      payload = {
        summary:
          "The repository contains a subtraction bug in src/add.js and no regression test.",
        relevantPaths: ["src/add.js", "test/add.test.js"],
        observations: [
          {
            statement: "add uses subtraction instead of addition.",
            evidenceArtifactIds: [],
          },
        ],
        risks: ["The fix must include executable regression coverage."],
      };
    } else if (
      this.resource.id === "lead" &&
      (role === "Lead" || requestedType === "PlanRequest")
    ) {
      messageType = "PlanResult";
      payload = {
        phases: [
          {
            phaseId: "phase-fix-add",
            name: "Fix and test",
            purpose: "Correct addition and prove it with a regression test.",
            tasks: [
              {
                taskId: "task-fix-add",
                objective: "Fix src/add.js and add test/add.test.js.",
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
      };
    } else if (
      this.resource.id === "lead" &&
      role === "Verifier" &&
      objective.includes("Verify completion criterion")
    ) {
      messageType = "VerificationResult";
      const inputs = (task.inputs ?? {}) as Record<string, unknown>;
      const criterion = inputs.completionCriterion as Record<string, unknown>;
      payload = {
        criterionId: String(criterion.id),
        method:
          criterion.id === "criterion-add-fixed"
            ? "independent_review"
            : "executable_check",
        outcome: "passed",
        evidenceArtifactIds: [],
        rationale:
          "The independent review and real pnpm test evidence satisfy the criterion.",
      };
    } else if (this.resource.id === "lead") {
      messageType = "CompletionResult";
      payload = {
        outcome: "completed",
        criteria: goal.completionCriteria.map((criterion) => ({
          criterionId: criterion.id,
          status: "satisfied",
          evidenceArtifactIds: [],
        })),
        finalReportArtifactId: "conclave-e2e-final-report",
        unresolvedFindingIds: [],
        remainingRisks: [],
      };
    } else if (this.resource.id === "implementer") {
      messageType = "ImplementationResult";
      payload = {
        status: "succeeded",
        revision: "fixture",
        changedFiles: ["src/add.js", "test/add.test.js"],
        artifactIds: [],
        proposedOperations: [
          {
            kind: "patch_file",
            path: "src/add.js",
            patches: [{ oldText: "return a - b", newText: "return a + b" }],
          },
          {
            kind: "write_file",
            path: "test/add.test.js",
            content:
              "import { test } from 'node:test';\nimport assert from 'node:assert/strict';\nimport { add } from '../src/add.js';\n\ntest('add sums two numbers', () => {\n  assert.equal(add(2, 3), 5);\n});\n",
          },
        ],
        testsRequested: ["pnpm test"],
        summary: "Fixed addition and added a regression test.",
        risks: [],
      };
    } else if (
      this.resource.id === "reviewer" &&
      role === "Reviewer" &&
      objective.includes("research")
    ) {
      messageType = "ResearchResult";
      payload = {
        summary:
          "The proposed fix is small and the missing regression test is the main risk.",
        relevantPaths: ["src/add.js", "test/add.test.js"],
        observations: [
          {
            statement:
              "The implementation should change only addition behavior and test coverage.",
            evidenceArtifactIds: [],
          },
        ],
        risks: [],
      };
    } else if (this.resource.id === "reviewer" && role === "Verifier") {
      messageType = "TestResult";
      payload = {
        revision: "fixture",
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
        summary: "The fixture test command passed.",
      };
    } else if (this.resource.id === "reviewer") {
      messageType = "ReviewResult";
      payload = {
        outcome: "pass",
        reviewedArtifactIds: [],
        resolvedFindingIds: [],
        findings: [],
        summary:
          "The actual changed files satisfy the goal and contain regression coverage.",
      };
    } else {
      throw new Error(
        `Unexpected request for ${this.resource.id}: ${role} ${objective}`,
      );
    }

    const text = envelope(request, this.resource.id, messageType, payload);
    return {
      providerRequestId: `${this.resource.id}-${this.requests.length}`,
      text,
      rawResponse: JSON.stringify({ output_text: text }),
      usage: { inputTokens: 20, outputTokens: 30 },
    };
  }
}

function operationBase(
  taskId: string,
  kind: RuntimeOperation["kind"],
  repositoryId: string,
): Omit<RuntimeOperation, "kind"> & { kind: RuntimeOperation["kind"] } {
  return {
    requestId: `runtime-${taskId}-${Date.now()}-${Math.random()}`,
    organizationId: "conclave-e2e-org",
    projectId: goal.projectId,
    runId: run.id,
    taskId,
    repositoryId,
    approval: {
      approvalId: `approval-${taskId}`,
      organizationId: "conclave-e2e-org",
      projectId: goal.projectId,
      runId: run.id,
      taskId,
      operationKinds: [kind],
      expiresAt: new Date(Date.now() + 60_000).toISOString(),
    },
    kind,
  } as Omit<RuntimeOperation, "kind"> & { kind: RuntimeOperation["kind"] };
}

describe("first real Conclave AX Forge fixture", () => {
  it("uses two model roles, mutates a real repository, and runs its real tests", async () => {
    const root = await mkdtemp(join(tmpdir(), "conclave-e2e-"));
    const repositoryRoot = join(root, "conclave-e2e-fixture");
    await cp(fixture, repositoryRoot, { recursive: true });
    const repositoryId = "conclave-e2e-fixture";
    const local = new LocalRuntime({
      repositories: [{ id: repositoryId, root: repositoryRoot }],
      allowedCommands: {
        shell: ["pnpm"],
        check: ["pnpm"],
        build: ["pnpm"],
      },
    });
    const runtime: ForgeRuntimeAdapter = {
      async inspect(input) {
        const search = await local.execute({
          ...operationBase(input.taskId, "search", repositoryId),
          kind: "search",
          query: "return a - b",
          path: ".",
        });
        const source = await local.execute({
          ...operationBase(input.taskId, "read_file", repositoryId),
          kind: "read_file",
          path: "src/add.js",
        });
        return {
          operation: "research",
          status:
            search.status === "succeeded" && source.status === "succeeded"
              ? "succeeded"
              : "failed",
          summary: "Repository inspected by Local Runtime",
          content: `${search.content}\n${source.content}`,
          contentDigest: search.contentDigest,
        };
      },
      async apply(input) {
        const evidence = [];
        for (const operation of input.operations) {
          const base = operationBase(
            input.taskId,
            operation.kind,
            repositoryId,
          );
          evidence.push(
            await local.execute({ ...base, ...operation } as RuntimeOperation),
          );
        }
        const files = await Promise.all(
          input.implementation.changedFiles.map(
            async (path) =>
              `${path}:\n${await readFile(join(repositoryRoot, path), "utf8")}`,
          ),
        );
        return {
          operation: "apply",
          status: evidence.every((item) => item.status === "succeeded")
            ? "succeeded"
            : "failed",
          summary: "Local Runtime applied the implementation operations",
          content: `${evidence.map((item) => item.content).join("\n")}\n${files.join("\n")}`,
          contentDigest: evidence.at(-1)?.contentDigest ?? "empty",
        };
      },
      async test(input) {
        const result = await local.execute({
          ...operationBase(input.taskId, "check", repositoryId),
          kind: "check",
          command: ["pnpm", "test"],
          cwd: ".",
        });
        return {
          operation: "test",
          status: result.status === "succeeded" ? "succeeded" : "failed",
          summary: result.summary,
          content: result.content,
          contentDigest: result.contentDigest,
          command: result.command ?? ["pnpm", "test"],
          exitCode: result.exitCode,
        };
      },
    };
    const lead = new ScenarioModel(
      resource("lead", ["lead"], ["planning", "evaluation", "repository_read"]),
    );
    const reviewer = new ScenarioModel(
      resource(
        "reviewer",
        ["reviewer", "verifier"],
        ["repository_read", "code_review", "risk_analysis", "test_execution"],
      ),
    );
    const implementer = new ScenarioModel(
      resource("implementer", ["implementer"], ["repository_write"]),
    );
    const persistence = new InMemoryForgePersistence();

    const result = await executeForgeGoal({
      goal,
      run,
      repositoryId,
      revision: "fixture",
      lead,
      implementer,
      reviewer,
      runtime,
      persistence,
      idFactory: (() => {
        let value = 0;
        return () => `conclave-e2e-${++value}`;
      })(),
      now: () => "2026-09-21T10:00:00.000Z",
    });

    expect(result.completion.payload.outcome).toBe("completed");
    expect(result.tests.payload.outcome).toBe("pass");
    expect(
      await readFile(join(repositoryRoot, "src/add.js"), "utf8"),
    ).toContain("return a + b");
    expect(
      await readFile(join(repositoryRoot, "test/add.test.js"), "utf8"),
    ).toContain("add(2, 3)");
    expect(
      reviewer.requests.some((request) =>
        request.context?.some((item) => item.content.includes("return a + b")),
      ),
    ).toBe(true);
    expect(persistence.events.at(-1)?.eventType).toBe("RunCompleted");
  }, 30_000);
});
