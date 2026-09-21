import { describe, expect, it } from "vitest";
import {
  PlanResultSchema,
  parseMachineCheckEvidence,
  parseModelResult,
  parsePlanRequest,
  parseProtocolMessage,
  PROTOCOL_NAME,
  PROTOCOL_VERSION,
  ReviewResultSchema,
} from "../src/index.js";

const envelope = {
  protocol: PROTOCOL_NAME,
  version: PROTOCOL_VERSION,
  messageId: "message-1",
  goalId: "goal-1",
  runId: "run-1",
  workerId: "worker-1",
  createdAt: "2026-09-21T10:00:00.000Z",
};

const validPlanResult = {
  ...envelope,
  messageType: "PlanResult",
  payload: {
    phases: [
      {
        phaseId: "phase-1",
        name: "Research",
        purpose: "Understand the repository",
        tasks: [
          {
            taskId: "task-1",
            objective: "Inspect source",
            role: "Researcher",
            capabilities: ["repository_inspection"],
            dependsOnTaskIds: [],
            requiresIndependentVerification: false,
          },
        ],
      },
    ],
    assumptions: [],
    risks: [],
  },
};

describe("versioned protocol contracts", () => {
  it("accepts a valid result and preserves its typed shape", () => {
    const result = parseModelResult(validPlanResult);
    expect(result.messageType).toBe("PlanResult");
    const plan = PlanResultSchema.parse(result);
    expect(plan.payload.phases[0]?.tasks[0]?.taskId).toBe("task-1");
  });

  it.each([
    ["missing protocol version", { ...validPlanResult, version: "0.2" }],
    ["unknown envelope field", { ...validPlanResult, unexpected: true }],
    [
      "missing required payload",
      { ...validPlanResult, payload: { phases: [] } },
    ],
    [
      "invalid nested field",
      {
        ...validPlanResult,
        payload: {
          ...validPlanResult.payload,
          phases: [
            {
              ...validPlanResult.payload.phases[0]!,
              tasks: [
                { ...validPlanResult.payload.phases[0]!.tasks[0]!, role: "" },
              ],
            },
          ],
        },
      },
    ],
  ])("rejects %s", (_description, input) => {
    expect(() => parseModelResult(input)).toThrow();
  });

  it("rejects a review result with an unknown field", () => {
    const review = {
      ...envelope,
      messageType: "ReviewResult",
      payload: {
        outcome: "pass",
        reviewedArtifactIds: [],
        resolvedFindingIds: [],
        findings: [],
        summary: "No issues found",
        hallucinatedClaim: "tests passed",
      },
    };

    expect(ReviewResultSchema.safeParse(review).success).toBe(false);
  });

  it("does not accept malformed input through an individual schema", () => {
    expect(PlanResultSchema.safeParse({}).success).toBe(false);
  });

  it("validates requests through the same runtime boundary", () => {
    const request = {
      ...envelope,
      messageType: "PlanRequest",
      payload: {
        objective: "Add protocol validation",
        constraints: [],
        repository: { repositoryId: "repo-1", revision: "main" },
        completionCriteria: ["Malformed output is rejected"],
      },
    };

    expect(parsePlanRequest(request).payload.objective).toBe(
      "Add protocol validation",
    );
    expect(parseProtocolMessage(request).messageType).toBe("PlanRequest");
    expect(() =>
      parseProtocolMessage({ ...request, version: "0.2" }),
    ).toThrow();
  });

  it("accepts machine evidence and rejects unverified check claims", () => {
    const evidence = parseMachineCheckEvidence({
      evidenceId: "evidence-1",
      source: "github_actions",
      externalRunId: "run-100",
      revision: "abc123",
      workflow: "CI",
      conclusion: "success",
      checks: [
        {
          name: "compile",
          status: "passed",
          command: "pnpm typecheck",
          exitCode: 0,
          artifactIds: [],
        },
      ],
      smokeTests: [],
      healthChecks: ["/health: 200"],
      observedAt: "2026-09-21T10:00:00.000Z",
    });
    expect(evidence.checks[0]?.status).toBe("passed");
    expect(() =>
      parseMachineCheckEvidence({
        ...evidence,
        conclusion: "success",
        checks: [],
      }),
    ).toThrow();
  });

  it("requires executable operations for successful implementations", () => {
    const implementation = {
      ...envelope,
      messageType: "ImplementationResult",
      payload: {
        status: "succeeded",
        revision: "main",
        changedFiles: ["src/file.ts"],
        proposedOperations: [],
        artifactIds: [],
        testsRequested: [],
        summary: "Changed the file",
        risks: [],
      },
    };
    expect(() => parseModelResult(implementation)).toThrow();
    expect(
      parseModelResult({
        ...implementation,
        payload: {
          ...implementation.payload,
          proposedOperations: [
            { kind: "write_file", path: "src/file.ts", content: "export {};" },
          ],
        },
      }).messageType,
    ).toBe("ImplementationResult");
  });
});
