import { z } from "zod";

export const PROTOCOL_NAME = "conclave.protocol" as const;
export const PROTOCOL_VERSION = "0.1" as const;

const id = z.string().min(1);
const nonEmpty = z.string().min(1);
const artifactIds = z.array(id);
const envelopeFields = {
  protocol: z.literal(PROTOCOL_NAME),
  version: z.literal(PROTOCOL_VERSION),
  messageId: id,
  goalId: id,
  runId: id,
  workerId: id,
  createdAt: z.iso.datetime(),
};

const repositoryContext = z
  .object({
    repositoryId: id,
    revision: nonEmpty,
  })
  .strict();

const message = <TMessageType extends string, TPayload extends z.ZodType>(
  messageType: TMessageType,
  payload: TPayload,
) =>
  z
    .object({
      ...envelopeFields,
      messageType: z.literal(messageType),
      payload,
    })
    .strict();

const planRequestPayload = z
  .object({
    taskId: id,
    objective: nonEmpty,
    constraints: z.array(nonEmpty),
    repository: repositoryContext,
    completionCriteria: z.array(nonEmpty).min(1),
  })
  .strict();

const taskPlan = z
  .object({
    taskId: id,
    objective: nonEmpty,
    role: nonEmpty,
    capabilities: z.array(nonEmpty).min(1),
    dependsOnTaskIds: z.array(id),
    requiresIndependentVerification: z.boolean(),
  })
  .strict();

const phasePlan = z
  .object({
    phaseId: id,
    name: nonEmpty,
    purpose: nonEmpty,
    tasks: z.array(taskPlan).min(1),
  })
  .strict();

const planResultPayload = z
  .object({
    taskId: id,
    phases: z.array(phasePlan).min(1),
    assumptions: z.array(nonEmpty),
    risks: z.array(nonEmpty),
  })
  .strict();

const taskRequestPayload = z
  .object({
    taskId: id,
    objective: nonEmpty,
    role: nonEmpty,
    requiredCapabilities: z.array(nonEmpty).min(1),
    contextArtifactIds: artifactIds,
    inputs: z.record(z.string(), z.unknown()),
  })
  .strict();

const taskResultPayload = z
  .object({
    taskId: id,
    status: z.enum(["succeeded", "blocked", "failed"]),
    summary: nonEmpty,
    artifactIds,
    findingIds: z.array(id),
  })
  .strict();

const researchResultPayload = z
  .object({
    taskId: id,
    summary: nonEmpty,
    relevantPaths: z.array(nonEmpty),
    observations: z
      .array(
        z
          .object({
            statement: nonEmpty,
            evidenceArtifactIds: artifactIds,
          })
          .strict(),
      )
      .min(1),
    risks: z.array(nonEmpty),
  })
  .strict();

const filePatch = z
  .object({
    oldText: z.string(),
    newText: z.string(),
    maxReplacements: z.number().int().min(1).optional(),
  })
  .strict();

const implementationOperation = z.discriminatedUnion("kind", [
  z
    .object({
      kind: z.literal("write_file"),
      path: nonEmpty,
      content: z.string(),
      expectedDigest: id.optional(),
    })
    .strict(),
  z
    .object({
      kind: z.literal("patch_file"),
      path: nonEmpty,
      patches: z.array(filePatch).min(1),
      expectedDigest: id.optional(),
    })
    .strict(),
  z
    .object({
      kind: z.literal("delete_file"),
      path: nonEmpty,
      expectedDigest: id.optional(),
    })
    .strict(),
]);

const implementationResultPayload = z
  .object({
    taskId: id,
    status: z.enum(["succeeded", "blocked", "failed"]),
    revision: nonEmpty,
    changedFiles: z.array(nonEmpty),
    proposedOperations: z.array(implementationOperation),
    artifactIds,
    testsRequested: z.array(nonEmpty),
    summary: nonEmpty,
    risks: z.array(nonEmpty),
  })
  .strict()
  .refine(
    (value) =>
      value.status !== "succeeded" || value.proposedOperations.length > 0,
    "A successful implementation must propose at least one operation",
  );

const finding = z
  .object({
    findingId: id,
    severity: z.enum(["blocker", "major", "minor", "note"]),
    scope: nonEmpty,
    description: nonEmpty,
    evidenceArtifactIds: artifactIds,
  })
  .strict();

const reviewResultPayload = z
  .object({
    taskId: id,
    outcome: z.enum(["pass", "changes_requested", "blocked"]),
    reviewedArtifactIds: artifactIds,
    resolvedFindingIds: artifactIds,
    findings: z.array(finding),
    summary: nonEmpty,
  })
  .strict();

const checkResult = z
  .object({
    name: nonEmpty,
    status: z.enum(["passed", "failed", "skipped", "inconclusive"]),
    command: nonEmpty.optional(),
    exitCode: z.number().int().optional(),
    artifactIds,
  })
  .strict();

const machineCheckEvidencePayload = z
  .object({
    evidenceId: id,
    source: z.enum(["github_actions", "local_runtime", "ci"]),
    externalRunId: nonEmpty,
    revision: nonEmpty,
    workflow: nonEmpty,
    conclusion: z.enum(["success", "failure", "cancelled", "neutral"]),
    checks: z.array(checkResult).min(1),
    coveragePercent: z.number().min(0).max(100).optional(),
    previewUrl: z.url().optional(),
    smokeTests: z.array(nonEmpty),
    healthChecks: z.array(nonEmpty),
    observedAt: z.iso.datetime(),
  })
  .strict();

const testResultPayload = z
  .object({
    taskId: id,
    revision: nonEmpty,
    outcome: z.enum(["pass", "fail", "inconclusive"]),
    checks: z.array(checkResult).min(1),
    summary: nonEmpty,
  })
  .strict();

const verificationResultPayload = z
  .object({
    taskId: id,
    criterionId: id,
    method: z.enum([
      "executable_check",
      "independent_review",
      "policy_check",
      "human_approval",
    ]),
    outcome: z.enum(["passed", "failed", "waived", "inconclusive"]),
    evidenceArtifactIds: artifactIds,
    rationale: nonEmpty,
  })
  .strict();

const decisionResultPayload = z
  .object({
    decisionType: z.enum([
      "accept_plan",
      "retry",
      "accept_finding",
      "dismiss_finding",
      "reopen",
      "waive",
      "complete",
      "fail",
    ]),
    outcome: z.enum(["accepted", "rejected"]),
    rationale: nonEmpty,
    evidenceArtifactIds: artifactIds,
    transitions: z
      .array(
        z
          .object({
            entityType: z.enum(["goal", "run", "phase", "task", "finding"]),
            entityId: id,
            from: nonEmpty,
            to: nonEmpty,
          })
          .strict(),
      )
      .min(1),
  })
  .strict();

const completionResultPayload = z
  .object({
    taskId: id,
    outcome: z.enum(["completed", "failed"]),
    criteria: z
      .array(
        z
          .object({
            criterionId: id,
            status: z.enum(["satisfied", "failed", "waived", "inconclusive"]),
            evidenceArtifactIds: artifactIds,
          })
          .strict(),
      )
      .min(1),
    finalReportArtifactId: id,
    unresolvedFindingIds: z.array(id),
    remainingRisks: z.array(nonEmpty),
  })
  .strict();

export const PlanRequestSchema = message("PlanRequest", planRequestPayload);
export const PlanResultSchema = message("PlanResult", planResultPayload);
export const TaskRequestSchema = message("TaskRequest", taskRequestPayload);
export const TaskResultSchema = message("TaskResult", taskResultPayload);
export const ResearchResultSchema = message(
  "ResearchResult",
  researchResultPayload,
);
export const ImplementationResultSchema = message(
  "ImplementationResult",
  implementationResultPayload,
);
export const ReviewResultSchema = message("ReviewResult", reviewResultPayload);
export const TestResultSchema = message("TestResult", testResultPayload);
export const MachineCheckEvidenceSchema = machineCheckEvidencePayload;
export const VerificationResultSchema = message(
  "VerificationResult",
  verificationResultPayload,
);
export const DecisionResultSchema = message(
  "DecisionResult",
  decisionResultPayload,
);
export const CompletionResultSchema = message(
  "CompletionResult",
  completionResultPayload,
);

export const ModelResultSchema = z.discriminatedUnion("messageType", [
  PlanResultSchema,
  TaskResultSchema,
  ResearchResultSchema,
  ImplementationResultSchema,
  ReviewResultSchema,
  TestResultSchema,
  VerificationResultSchema,
  DecisionResultSchema,
  CompletionResultSchema,
]);

export const ProtocolMessageSchema = z.discriminatedUnion("messageType", [
  PlanRequestSchema,
  TaskRequestSchema,
  PlanResultSchema,
  TaskResultSchema,
  ResearchResultSchema,
  ImplementationResultSchema,
  ReviewResultSchema,
  TestResultSchema,
  VerificationResultSchema,
  DecisionResultSchema,
  CompletionResultSchema,
]);

export type PlanRequest = z.infer<typeof PlanRequestSchema>;
export type PlanResult = z.infer<typeof PlanResultSchema>;
export type TaskRequest = z.infer<typeof TaskRequestSchema>;
export type TaskResult = z.infer<typeof TaskResultSchema>;
export type ResearchResult = z.infer<typeof ResearchResultSchema>;
export type ImplementationResult = z.infer<typeof ImplementationResultSchema>;
export type ImplementationOperation = z.infer<typeof implementationOperation>;
export type ReviewResult = z.infer<typeof ReviewResultSchema>;
export type TestResult = z.infer<typeof TestResultSchema>;
export type MachineCheckEvidence = z.infer<typeof MachineCheckEvidenceSchema>;
export type VerificationResult = z.infer<typeof VerificationResultSchema>;
export type DecisionResult = z.infer<typeof DecisionResultSchema>;
export type CompletionResult = z.infer<typeof CompletionResultSchema>;
export type ModelResult = z.infer<typeof ModelResultSchema>;
export type ProtocolMessage = z.infer<typeof ProtocolMessageSchema>;

export interface ResponseContext {
  readonly goalId: string;
  readonly runId: string;
  readonly workerId: string;
  readonly taskId: string;
  readonly expectedMessageType: ModelResult["messageType"];
}

export class ResponseContextError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ResponseContextError";
  }
}

export function validateResponseContext(
  response: ModelResult,
  expected: ResponseContext,
): void {
  if (response.messageType !== expected.expectedMessageType) {
    throw new ResponseContextError(
      `Expected ${expected.expectedMessageType}, received ${response.messageType}`,
    );
  }
  const payload = response.payload as { readonly taskId?: unknown };
  for (const [field, actual, wanted] of [
    ["goalId", response.goalId, expected.goalId],
    ["runId", response.runId, expected.runId],
    ["workerId", response.workerId, expected.workerId],
    ["taskId", payload.taskId, expected.taskId],
  ] as const) {
    if (actual !== wanted) {
      throw new ResponseContextError(
        `Response ${field} ${String(actual)} does not match ${String(wanted)}`,
      );
    }
  }
}

export function parsePlanRequest(input: unknown): PlanRequest {
  return PlanRequestSchema.parse(input);
}

export function parseTaskRequest(input: unknown): TaskRequest {
  return TaskRequestSchema.parse(input);
}

export function parseImplementationResult(
  input: unknown,
): ImplementationResult {
  return ImplementationResultSchema.parse(input);
}

export function parseMachineCheckEvidence(
  input: unknown,
): MachineCheckEvidence {
  return MachineCheckEvidenceSchema.parse(input);
}

export function parseModelResult(input: unknown): ModelResult {
  return ModelResultSchema.parse(input);
}

export function parseProtocolMessage(input: unknown): ProtocolMessage {
  return ProtocolMessageSchema.parse(input);
}
