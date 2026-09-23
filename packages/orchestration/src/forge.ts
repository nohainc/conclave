import type {
  ArtifactRecord,
  AttemptRecord,
  FindingRecord,
  GoalRecord,
  JsonValue,
  ModelCallRecord,
  PhaseRecord,
  RunEventRecord,
  RunRecord,
  TaskRecord,
  TaskDependencyRecord,
  VerificationRecord,
} from "@conclave/persistence";
import {
  CompletionCriteriaGate,
  createIsolatedReviewContext,
  getVerificationPolicy,
  validateTaskGraph,
  VerificationGate,
  type Finding,
} from "@conclave/core";
import type {
  ExecutionHost,
  Worker,
  WorkerAssignmentResult,
} from "@conclave/core";
import {
  ContextBuilder,
  type ArtifactResolver,
  type ContextLimits,
} from "./context.js";
import {
  parseModelResult,
  parseImplementationResult,
  validateResponseContext,
  type CompletionResult,
  type ImplementationOperation,
  type ImplementationResult,
  type ModelResult,
  type PlanRequest,
  type PlanResult,
  type ResearchResult,
  type ReviewResult,
  type TaskRequest,
  type TestResult,
  type VerificationResult,
} from "@conclave/protocol";

export interface ForgeRuntimeEvidence {
  readonly operation: "research" | "apply" | "test";
  readonly status: "succeeded" | "failed";
  readonly summary: string;
  readonly content: string;
  readonly contentDigest: string;
  readonly command?: readonly string[];
  readonly exitCode?: number | null;
  readonly checks?: readonly {
    readonly name: string;
    readonly status: "passed" | "failed" | "skipped" | "inconclusive";
    readonly command?: string;
    readonly exitCode?: number;
  }[];
}

/**
 * The Forge execution boundary is deliberately expressed in v3 entities.
 * Cloud selects a Worker hosted by an Agent; the implementation behind this
 * interface creates and observes a WorkerAssignment through AgentGateway.
 */
export interface ForgeWorkerRequest {
  readonly requestId: string;
  readonly goalId: string;
  readonly runId: string;
  readonly taskId: string;
  readonly attemptId: string;
  readonly repositoryId: string;
  readonly message: unknown;
  readonly context: readonly {
    readonly artifactId: string;
    readonly mediaType: string;
    readonly content: string;
    readonly truncated: boolean;
    readonly originalLength: number;
    readonly estimatedTokens: number;
  }[];
  readonly deadlineAt?: string;
}

export interface ForgeWorker {
  readonly worker: Worker;
  readonly agent: ExecutionHost;
  execute(request: ForgeWorkerRequest): Promise<WorkerAssignmentResult>;
}

export interface ForgeRuntimeAdapter {
  inspect(input: {
    readonly taskId: string;
    readonly repositoryId: string;
    readonly revision: string;
    readonly objective: string;
  }): Promise<ForgeRuntimeEvidence>;
  apply(input: {
    readonly taskId: string;
    readonly repositoryId: string;
    readonly revision: string;
    readonly implementation: ImplementationResult["payload"];
    readonly operations: readonly ImplementationOperation[];
  }): Promise<ForgeRuntimeEvidence>;
  test(input: {
    readonly taskId: string;
    readonly repositoryId: string;
    readonly revision: string;
    readonly changedFiles: readonly string[];
  }): Promise<ForgeRuntimeEvidence>;
}

export interface ForgeImplementationAgent {
  execute(input: {
    readonly task: TaskRecord;
    readonly plan: PlanResult;
    readonly research: ResearchResult;
    readonly secondaryResearch: ResearchResult | null;
    readonly runtime: ForgeRuntimeAdapter;
  }): Promise<{
    readonly implementation: ImplementationResult;
    readonly evidence: ForgeRuntimeEvidence;
  }>;
}

export interface ForgePersistence {
  saveGoal(goal: GoalRecord): Promise<void>;
  saveRun(run: RunRecord): Promise<void>;
  savePhase(phase: PhaseRecord): Promise<void>;
  saveTask(task: TaskRecord): Promise<void>;
  saveTaskDependency(dependency: TaskDependencyRecord): Promise<void>;
  saveAttempt(attempt: AttemptRecord): Promise<void>;
  saveModelCall(call: ModelCallRecord): Promise<void>;
  saveFinding(finding: FindingRecord): Promise<void>;
  saveVerification(verification: VerificationRecord): Promise<void>;
  saveArtifact(artifact: ArtifactRecord): Promise<void>;
  appendEvent(event: RunEventRecord): Promise<void>;
  resolve(artifactId: string): Promise<{
    readonly artifactId: string;
    readonly mediaType: string;
    readonly content: string;
  } | null>;
}

export interface ForgeWorkflowInput {
  readonly goal: GoalRecord;
  readonly run: RunRecord;
  readonly repositoryId: string;
  readonly revision: string;
  readonly lead: ForgeWorker;
  readonly implementer: ForgeWorker;
  readonly reviewer?: ForgeWorker;
  readonly secondaryResearcher?: ForgeWorker;
  readonly requireSecondaryResearch?: boolean;
  readonly runtime: ForgeRuntimeAdapter;
  readonly implementationAgent?: ForgeImplementationAgent;
  readonly validationFallbackWorker?: ForgeWorker;
  readonly persistence: ForgePersistence;
  readonly maxReviewLoops?: number;
  readonly idFactory?: () => string;
  readonly now?: () => string;
  readonly contextLimits?: ContextLimits;
  readonly maxValidationAttempts?: number;
}

export interface ForgeWorkflowResult {
  readonly research: ResearchResult;
  readonly secondaryResearch: ResearchResult | null;
  readonly plan: PlanResult;
  readonly implementation: ImplementationResult;
  readonly reviews: readonly ReviewResult[];
  readonly tests: TestResult;
  readonly machineEvidence: ForgeRuntimeEvidence;
  readonly verification: readonly VerificationResult[];
  readonly completion: CompletionResult;
  readonly correctionLoops: number;
}

export class InMemoryForgePersistence implements ForgePersistence {
  readonly goals: GoalRecord[] = [];
  readonly runs: RunRecord[] = [];
  readonly phases: PhaseRecord[] = [];
  readonly tasks: TaskRecord[] = [];
  readonly taskDependencies: TaskDependencyRecord[] = [];
  readonly attempts: AttemptRecord[] = [];
  readonly modelCalls: ModelCallRecord[] = [];
  readonly findings: FindingRecord[] = [];
  readonly verifications: VerificationRecord[] = [];
  readonly artifacts: ArtifactRecord[] = [];
  readonly events: RunEventRecord[] = [];

  saveGoal(goal: GoalRecord): Promise<void> {
    this.goals.push(goal);
    return Promise.resolve();
  }
  saveRun(run: RunRecord): Promise<void> {
    this.runs.push(run);
    return Promise.resolve();
  }
  savePhase(phase: PhaseRecord): Promise<void> {
    this.phases.push(phase);
    return Promise.resolve();
  }
  saveTask(task: TaskRecord): Promise<void> {
    this.tasks.push(task);
    return Promise.resolve();
  }
  saveTaskDependency(dependency: TaskDependencyRecord): Promise<void> {
    this.taskDependencies.push(dependency);
    return Promise.resolve();
  }
  saveAttempt(attempt: AttemptRecord): Promise<void> {
    this.attempts.push(attempt);
    return Promise.resolve();
  }
  saveModelCall(call: ModelCallRecord): Promise<void> {
    this.modelCalls.push(call);
    return Promise.resolve();
  }
  saveFinding(finding: FindingRecord): Promise<void> {
    const index = this.findings.findIndex(
      (candidate) => candidate.id === finding.id,
    );
    if (index >= 0) this.findings[index] = finding;
    else this.findings.push(finding);
    return Promise.resolve();
  }
  saveVerification(verification: VerificationRecord): Promise<void> {
    this.verifications.push(verification);
    return Promise.resolve();
  }
  saveArtifact(artifact: ArtifactRecord): Promise<void> {
    this.artifacts.push(artifact);
    return Promise.resolve();
  }
  appendEvent(event: RunEventRecord): Promise<void> {
    this.events.push(event);
    return Promise.resolve();
  }

  resolve(artifactId: string) {
    const artifact = this.artifacts.find(
      (candidate) => candidate.id === artifactId,
    );
    if (!artifact || artifact.payload.kind !== "inline")
      return Promise.resolve(null);
    return Promise.resolve({
      artifactId: artifact.id,
      mediaType: artifact.mediaType,
      content: artifact.payload.content,
    });
  }
}

function defaultId(): string {
  return crypto.randomUUID();
}

function jsonObject(value: unknown): JsonValue {
  return JSON.parse(JSON.stringify(value)) as JsonValue;
}

async function sha256(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const result = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(result)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function expectedResult<T extends ModelResult["messageType"]>(
  result: ModelResult,
  messageType: T,
): Extract<ModelResult, { messageType: T }> {
  if (result.messageType !== messageType) {
    throw new Error(`Expected ${messageType}, received ${result.messageType}`);
  }
  return result as Extract<ModelResult, { messageType: T }>;
}

class ModelResponseValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ModelResponseValidationError";
  }
}

export async function executeForgeGoal(
  input: ForgeWorkflowInput,
): Promise<ForgeWorkflowResult> {
  const reviewer = input.reviewer ?? input.lead;
  if (input.implementer.worker.id === reviewer.worker.id) {
    throw new Error("Forge requires a reviewer different from the implementer");
  }
  const maxReviewLoops = input.maxReviewLoops ?? 2;
  if (maxReviewLoops < 1) throw new Error("maxReviewLoops must be positive");

  const id = input.idFactory ?? defaultId;
  const now = input.now ?? (() => new Date().toISOString());
  const persistence = input.persistence;
  const contextBuilder = new ContextBuilder(
    input.persistence satisfies ArtifactResolver,
    input.contextLimits,
  );
  const maxValidationAttempts = input.maxValidationAttempts ?? 2;
  if (maxValidationAttempts < 1) {
    throw new Error("maxValidationAttempts must be positive");
  }
  let sequence = 0;
  const phases = new Map<string, string>();
  const persistedFindings = new Map<string, FindingRecord>();

  const event = async (
    eventType: string,
    entityType: string,
    entityId: string,
    payload: JsonValue,
  ) => {
    await persistence.appendEvent({
      runId: input.run.id,
      sequence: ++sequence,
      id: id(),
      eventType,
      entityType,
      entityId,
      correlationId: input.run.id,
      payload,
      occurredAt: now(),
    });
  };

  const phase = async (name: string, purpose: string, order: number) => {
    const phaseRecord: PhaseRecord = {
      id: id(),
      runId: input.run.id,
      name,
      purpose,
      sequence: order,
      status: "running",
      createdAt: now(),
      updatedAt: now(),
    };
    phases.set(name, phaseRecord.id);
    await persistence.savePhase(phaseRecord);
    await event("PhaseStarted", "phase", phaseRecord.id, { name, purpose });
    return phaseRecord;
  };

  const task = async (
    phaseId: string,
    objective: string,
    role: string,
    capabilities: readonly string[],
    outputContract: string,
  ): Promise<TaskRecord> => {
    const record: TaskRecord = {
      id: id(),
      phaseId,
      objective,
      role,
      capabilities,
      input: { repositoryId: input.repositoryId, revision: input.revision },
      outputContract: { messageType: outputContract },
      status: "running",
      requiresIndependentVerification: role.toLowerCase() === "reviewer",
      createdAt: now(),
      updatedAt: now(),
    };
    await persistence.saveTask(record);
    await event("TaskStarted", "task", record.id, {
      objective,
      role,
      outputContract,
    });
    return record;
  };

  const artifact = async (
    taskId: string,
    content: string,
    mediaType: string,
    provenance: JsonValue,
  ): Promise<string> => {
    const artifactId = id();
    await persistence.saveArtifact({
      id: artifactId,
      runId: input.run.id,
      taskId,
      attemptId: null,
      mediaType,
      payload: { kind: "inline", content },
      contentDigest: await sha256(content),
      sizeBytes: new TextEncoder().encode(content).byteLength,
      provenance,
      createdAt: now(),
    });
    await event("ArtifactCreated", "artifact", artifactId, provenance);
    return artifactId;
  };

  const runtimeArtifact = async (
    taskId: string,
    evidence: ForgeRuntimeEvidence,
  ): Promise<string> => {
    if (evidence.status !== "succeeded") {
      throw new Error(
        `${evidence.operation} runtime operation failed: ${evidence.summary}`,
      );
    }
    return artifact(taskId, evidence.content, "text/plain", {
      kind: "runtime_evidence",
      operation: evidence.operation,
      summary: evidence.summary,
      contentDigest: evidence.contentDigest,
      ...(evidence.command ? { command: [...evidence.command] } : {}),
      ...(evidence.exitCode !== undefined
        ? { exitCode: evidence.exitCode }
        : {}),
    });
  };

  const persistFinding = async (
    finding: Finding,
    evidenceArtifactIds: readonly string[] = [],
  ): Promise<void> => {
    const previous = persistedFindings.get(finding.findingId);
    const record: FindingRecord = {
      id: finding.findingId,
      runId: input.run.id,
      taskId: finding.taskId,
      sourceAttemptId: null,
      severity: finding.severity,
      scope: "independent_review",
      description: finding.description,
      evidenceArtifactIds: evidenceArtifactIds.length
        ? [...evidenceArtifactIds]
        : (previous?.evidenceArtifactIds ?? []),
      status: finding.status,
      createdAt: previous?.createdAt ?? now(),
      updatedAt: now(),
    };
    persistedFindings.set(record.id, record);
    await persistence.saveFinding(record);
  };

  const persistVerification = async (record: VerificationRecord) => {
    await persistence.saveVerification(record);
  };

  const callOnce = async <T extends ModelResult["messageType"]>(
    worker: ForgeWorker,
    modelTask: TaskRecord,
    request: PlanRequest | TaskRequest,
    expected: T,
    contextArtifactIds: readonly string[] = [],
    attemptNumber = 1,
  ): Promise<Extract<ModelResult, { messageType: T }>> => {
    const attemptId = id();
    const startedAt = now();
    const modelRequest = {
      message: request,
      context: await contextBuilder.build(contextArtifactIds),
    };
    const requestArtifactId = await artifact(
      modelTask.id,
      JSON.stringify(modelRequest),
      "application/json",
      {
        kind: "protocol_request",
        messageType: request.messageType,
        workerId: worker.worker.id,
      },
    );
    await persistence.saveAttempt({
      id: attemptId,
      taskId: modelTask.id,
      workerId: worker.worker.id,
      attemptNumber,
      inputSnapshot: jsonObject(request),
      outputArtifactIds: [requestArtifactId],
      status: "running",
      failureClass: null,
      startedAt,
      finishedAt: null,
    });
    await event("ModelRequestSent", "attempt", attemptId, {
      messageType: request.messageType,
      workerId: worker.worker.id,
    });

    let response: WorkerAssignmentResult;
    try {
      response = await worker.execute({
        requestId: id(),
        goalId: request.goalId,
        runId: request.runId,
        taskId: modelTask.id,
        attemptId,
        repositoryId: input.repositoryId,
        message: request,
        context: modelRequest.context ?? [],
      });
      if (response.status !== "completed" || response.output === null) {
        throw new Error(
          response.error?.message ??
            `Worker execution ended with status ${response.status}`,
        );
      }
    } catch (error) {
      await persistence.saveModelCall({
        id: id(),
        attemptId,
        workerId: worker.worker.id,
        connectionId: worker.agent.id,
        provider: worker.worker.workerCatalogId,
        model: worker.worker.name,
        requestArtifactId,
        responseArtifactId: null,
        status: "failed",
        inputTokens: null,
        outputTokens: null,
        startedAt,
        finishedAt: now(),
      });
      await persistence.saveAttempt({
        id: attemptId,
        taskId: modelTask.id,
        workerId: worker.worker.id,
        attemptNumber,
        inputSnapshot: jsonObject(request),
        outputArtifactIds: [requestArtifactId],
        status: "failed",
        failureClass: "worker",
        startedAt,
        finishedAt: now(),
      });
      await event("ModelCallFailed", "attempt", attemptId, {
        reason: error instanceof Error ? error.message : "unknown",
      });
      throw error;
    }

    const responseArtifactId = await artifact(
      modelTask.id,
      JSON.stringify(response.output),
      "application/json",
      {
        kind: "provider_response",
        workerId: worker.worker.id,
      },
    );
    await persistence.saveModelCall({
      id: id(),
      attemptId,
      workerId: worker.worker.id,
      connectionId: worker.agent.id,
      provider: worker.worker.workerCatalogId,
      model: worker.worker.name,
      requestArtifactId,
      responseArtifactId,
      status: "completed",
      inputTokens: null,
      outputTokens: null,
      startedAt,
      finishedAt: now(),
    });
    try {
      const parsed = parseModelResult(response.output);
      validateResponseContext(parsed, {
        goalId: request.goalId,
        runId: request.runId,
        workerId: worker.worker.id,
        taskId: modelTask.id,
        expectedMessageType: expected,
      });
      const accepted = expectedResult(parsed, expected);
      await persistence.saveAttempt({
        id: attemptId,
        taskId: modelTask.id,
        workerId: worker.worker.id,
        attemptNumber,
        inputSnapshot: jsonObject(request),
        outputArtifactIds: [requestArtifactId, responseArtifactId],
        status: "succeeded",
        failureClass: null,
        startedAt,
        finishedAt: now(),
      });
      await event("ModelResultAccepted", "attempt", attemptId, {
        messageType: accepted.messageType,
        responseArtifactId,
      });
      return accepted;
    } catch (error) {
      await persistence.saveAttempt({
        id: attemptId,
        taskId: modelTask.id,
        workerId: worker.worker.id,
        attemptNumber,
        inputSnapshot: jsonObject(request),
        outputArtifactIds: [requestArtifactId, responseArtifactId],
        status: "failed",
        failureClass: "validation",
        startedAt,
        finishedAt: now(),
      });
      await event("ModelResultRejected", "attempt", attemptId, {
        reason: error instanceof Error ? error.message : "unknown",
      });
      throw new ModelResponseValidationError(
        error instanceof Error
          ? error.message
          : "Model response validation failed",
      );
    }
  };

  const call = async <T extends ModelResult["messageType"]>(
    worker: ForgeWorker,
    modelTask: TaskRecord,
    request: PlanRequest | TaskRequest,
    expected: T,
    contextArtifactIds: readonly string[] = [],
  ): Promise<Extract<ModelResult, { messageType: T }>> => {
    let lastError: unknown;
    for (let attempt = 1; attempt <= maxValidationAttempts; attempt += 1) {
      const activeWorker =
        attempt > 1 && input.validationFallbackWorker
          ? input.validationFallbackWorker
          : worker;
      const activeRequest =
        activeWorker.worker.id === request.workerId
          ? request
          : { ...request, workerId: activeWorker.worker.id };
      try {
        return await callOnce(
          activeWorker,
          modelTask,
          activeRequest,
          expected,
          contextArtifactIds,
          attempt,
        );
      } catch (error) {
        if (!(error instanceof ModelResponseValidationError)) throw error;
        lastError = error;
        await event("ModelValidationRetry", "task", modelTask.id, {
          attempt,
          maxAttempts: maxValidationAttempts,
          messageType: expected,
          rerouted: activeWorker.worker.id !== worker.worker.id,
          reason: error.message,
        });
      }
    }
    throw new Error(
      `Model response validation exhausted after ${maxValidationAttempts} attempts: ${lastError instanceof Error ? lastError.message : "unknown"}`,
    );
  };

  await persistence.saveGoal(input.goal);
  await persistence.saveRun(input.run);
  await event("GoalReceived", "goal", input.goal.id, {
    objective: input.goal.objective,
  });
  await event("RunStarted", "run", input.run.id, {
    repositoryId: input.repositoryId,
    revision: input.revision,
  });

  const researchPhase = await phase(
    "research",
    "Understand the repository and gather evidence",
    1,
  );
  const researchTask = await task(
    researchPhase.id,
    "Research the repository",
    "Researcher",
    ["repository_read"],
    "ResearchResult",
  );
  const researchEvidenceId = await runtimeArtifact(
    researchTask.id,
    await input.runtime.inspect({
      taskId: researchTask.id,
      repositoryId: input.repositoryId,
      revision: input.revision,
      objective: input.goal.objective,
    }),
  );
  const researchRequest: TaskRequest = {
    protocol: "conclave.protocol",
    version: "0.1",
    messageId: id(),
    goalId: input.goal.id,
    runId: input.run.id,
    workerId: input.lead.worker.id,
    createdAt: now(),
    messageType: "TaskRequest",
    payload: {
      taskId: researchTask.id,
      objective:
        "Research the repository and identify the smallest safe change",
      role: "Researcher",
      requiredCapabilities: ["repository_read"],
      contextArtifactIds: [researchEvidenceId],
      inputs: {
        runtimeEvidence: researchEvidenceId,
        objective: input.goal.objective,
      },
    },
  };
  const research = await call(
    input.lead,
    researchTask,
    researchRequest,
    "ResearchResult",
    [researchEvidenceId],
  );

  let secondaryResearch: ResearchResult | null = null;
  if (input.requireSecondaryResearch || research.payload.risks.length > 0) {
    const secondResearchTask = await task(
      researchPhase.id,
      "Independently challenge the repository research",
      "Reviewer",
      ["repository_read", "risk_analysis"],
      "ResearchResult",
    );
    const secondRequest: TaskRequest = {
      ...researchRequest,
      messageId: id(),
      workerId: (input.secondaryResearcher ?? reviewer).worker.id,
      payload: {
        ...researchRequest.payload,
        taskId: secondResearchTask.id,
        objective:
          "Challenge the first research result and identify missed risks",
        role: "Reviewer",
        requiredCapabilities: ["repository_read", "risk_analysis"],
        inputs: {
          primaryResearch: research.payload,
          runtimeEvidence: researchEvidenceId,
        },
      },
    };
    secondaryResearch = await call(
      input.secondaryResearcher ?? reviewer,
      secondResearchTask,
      secondRequest,
      "ResearchResult",
      [researchEvidenceId],
    );
  }

  const planningPhase = await phase(
    "planning",
    "Create a validated dependency-ordered plan",
    2,
  );
  const planningTask = await task(
    planningPhase.id,
    "Plan the requested repository change",
    "Lead",
    ["planning"],
    "PlanResult",
  );
  const planRequest: PlanRequest = {
    protocol: "conclave.protocol",
    version: "0.1",
    messageId: id(),
    goalId: input.goal.id,
    runId: input.run.id,
    workerId: input.lead.worker.id,
    createdAt: now(),
    messageType: "PlanRequest",
    payload: {
      taskId: planningTask.id,
      objective: input.goal.objective,
      constraints: [...input.goal.constraints],
      repository: {
        repositoryId: input.repositoryId,
        revision: input.revision,
      },
      completionCriteria: input.goal.completionCriteria.map(
        (criterion) => criterion.description,
      ),
    },
  };
  const plan = await call(input.lead, planningTask, planRequest, "PlanResult");
  const validatedPlan = validateTaskGraph(plan);
  if (validatedPlan.tasks.length === 0)
    throw new Error("Forge plan contains no tasks");

  // The model-proposed graph is an accepted Core-owned projection of the
  // plan. Preserve it with durable task IDs and dependencies before Forge
  // starts its implementation/review lifecycle. Provider-local task IDs must
  // never become foreign keys in persistence.
  const plannedTaskIds = new Map<string, string>();
  for (const plannedTask of validatedPlan.tasks) {
    plannedTaskIds.set(plannedTask.taskId, id());
  }
  for (const plannedTask of validatedPlan.tasks) {
    const persistedTaskId = plannedTaskIds.get(plannedTask.taskId)!;
    await persistence.saveTask({
      id: persistedTaskId,
      phaseId: planningPhase.id,
      objective: plannedTask.objective,
      role: plannedTask.role,
      capabilities: [...plannedTask.capabilities],
      input: {
        repositoryId: input.repositoryId,
        revision: input.revision,
        plannedTaskId: plannedTask.taskId,
        phaseId: plannedTask.phaseId,
      },
      outputContract: { messageType: "TaskResult" },
      status: "pending",
      requiresIndependentVerification:
        plannedTask.requiresIndependentVerification,
      createdAt: now(),
      updatedAt: now(),
    });
    for (const dependencyId of plannedTask.dependsOnTaskIds) {
      const dependsOnTaskId = plannedTaskIds.get(dependencyId);
      if (!dependsOnTaskId) {
        throw new Error(
          `Validated plan dependency was not materialized: ${dependencyId}`,
        );
      }
      await persistence.saveTaskDependency({
        taskId: persistedTaskId,
        dependsOnTaskId,
      });
    }
  }
  await event("PlanGraphAccepted", "phase", planningPhase.id, {
    phaseCount: validatedPlan.phases.length,
    taskCount: validatedPlan.tasks.length,
    taskIds: [...plannedTaskIds.values()],
  });

  const implementationPhase = await phase(
    "implementation",
    "Apply the accepted change to the repository",
    3,
  );
  const implementationTask = await task(
    implementationPhase.id,
    "Implement the accepted plan",
    "Implementer",
    ["repository_write"],
    "ImplementationResult",
  );
  const implementationRequest: TaskRequest = {
    ...researchRequest,
    messageId: id(),
    workerId: input.implementer.worker.id,
    payload: {
      ...researchRequest.payload,
      taskId: implementationTask.id,
      objective: "Implement the accepted plan in the repository",
      role: "Implementer",
      requiredCapabilities: ["repository_write"],
      inputs: {
        plan: plan.payload,
        research: research.payload,
        secondaryResearch: secondaryResearch?.payload ?? null,
      },
    },
  };
  let implementation: ImplementationResult;
  let implementationEvidenceId: string;
  if (input.implementationAgent) {
    const agentResult = await input.implementationAgent.execute({
      task: implementationTask,
      plan,
      research,
      secondaryResearch,
      runtime: input.runtime,
    });
    implementation = parseImplementationResult(agentResult.implementation);
    implementationEvidenceId = await runtimeArtifact(
      implementationTask.id,
      agentResult.evidence,
    );
  } else {
    implementation = await call(
      input.implementer,
      implementationTask,
      implementationRequest,
      "ImplementationResult",
      [researchEvidenceId],
    );
    implementationEvidenceId = await runtimeArtifact(
      implementationTask.id,
      await input.runtime.apply({
        taskId: implementationTask.id,
        repositoryId: input.repositoryId,
        revision: input.revision,
        implementation: implementation.payload,
        operations: implementation.payload.proposedOperations,
      }),
    );
  }

  const reviewPhase = await phase(
    "review",
    "Independently review the implementation and correct blocking findings",
    4,
  );
  const reviewTask = await task(
    reviewPhase.id,
    "Review the implementation independently",
    "Reviewer",
    ["code_review"],
    "ReviewResult",
  );
  createIsolatedReviewContext({
    reviewContextId: id(),
    implementationContextId: id(),
    reviewerWorkerId: reviewer.worker.id,
    authorWorkerId: input.implementer.worker.id,
    artifactIds: [],
  });
  const gate = new VerificationGate(getVerificationPolicy("high"));
  const reviews: ReviewResult[] = [];
  let correctionLoops = 0;
  let activeFindingIds: string[] = [];
  const pendingReReviewIds = new Set<string>();
  while (true) {
    const reviewRequest: TaskRequest = {
      ...researchRequest,
      messageId: id(),
      workerId: reviewer.worker.id,
      payload: {
        ...researchRequest.payload,
        taskId: reviewTask.id,
        objective:
          correctionLoops === 0
            ? "Review the implementation independently against the goal"
            : "Re-review the corrected implementation and prior findings",
        role: "Reviewer",
        requiredCapabilities: ["code_review"],
        inputs: {
          implementation: implementation.payload,
          plan: plan.payload,
          priorFindingIds: activeFindingIds,
        },
      },
    };
    const review = await call(
      reviewer,
      reviewTask,
      reviewRequest,
      "ReviewResult",
      [implementationEvidenceId],
    );
    reviews.push(review);
    const reviewVerificationId = id();
    gate.recordVerification({
      verificationId: reviewVerificationId,
      taskId: implementationTask.id,
      method: "independent_review",
      outcome: review.payload.outcome === "pass" ? "passed" : "failed",
      verifierWorkerId: reviewer.worker.id,
      independent: true,
    });
    await persistVerification({
      id: reviewVerificationId,
      runId: input.run.id,
      taskId: implementationTask.id,
      criterionId: "",
      verifierWorkerId: reviewer.worker.id,
      method: "independent_review",
      outcome: review.payload.outcome === "pass" ? "passed" : "failed",
      evidenceArtifactIds: [implementationEvidenceId],
      rationale: review.payload.summary,
      createdAt: now(),
    });
    for (const findingId of review.payload.resolvedFindingIds) {
      if (!pendingReReviewIds.has(findingId)) {
        throw new Error(
          `Reviewer resolved finding ${findingId} without a pending fix`,
        );
      }
      gate.verifyFinding(findingId, reviewer.worker.id);
      const verifiedFinding = gate
        .listFindings(implementationTask.id)
        .find((candidate) => candidate.findingId === findingId);
      if (verifiedFinding) await persistFinding(verifiedFinding);
      pendingReReviewIds.delete(findingId);
    }
    activeFindingIds = [];
    for (const protocolFinding of review.payload.findings) {
      const finding: Finding = {
        findingId: protocolFinding.findingId,
        taskId: implementationTask.id,
        severity: protocolFinding.severity,
        description: protocolFinding.description,
        authorWorkerId: input.implementer.worker.id,
        status: "open",
      };
      const existing = gate
        .listFindings(implementationTask.id)
        .find((candidate) => candidate.findingId === finding.findingId);
      if (existing) {
        if (existing.status === "fixed") gate.reopenFinding(finding.findingId);
        else if (existing.status !== "reopened" && existing.status !== "open") {
          throw new Error(
            `Reviewer returned finding ${finding.findingId} in invalid state ${existing.status}`,
          );
        }
      } else {
        gate.openFinding(finding);
      }
      await persistFinding(finding);
      if (gate.policy.blockingSeverities.includes(finding.severity))
        activeFindingIds.push(finding.findingId);
    }
    if (review.payload.outcome === "pass" && activeFindingIds.length === 0) {
      if (pendingReReviewIds.size > 0) {
        throw new Error(
          `Reviewer passed without resolving findings: ${[...pendingReReviewIds].join(", ")}`,
        );
      }
      break;
    }
    if (correctionLoops >= maxReviewLoops)
      throw new Error(
        `Forge review loop exhausted with findings: ${activeFindingIds.join(", ")}`,
      );
    correctionLoops += 1;
    const correctionTask = await task(
      implementationPhase.id,
      "Fix blocking independent review findings",
      "Implementer",
      ["repository_write"],
      "ImplementationResult",
    );
    const correctionRequest: TaskRequest = {
      ...implementationRequest,
      messageId: id(),
      workerId: input.implementer.worker.id,
      payload: {
        ...implementationRequest.payload,
        taskId: correctionTask.id,
        objective:
          "Fix every blocking review finding and preserve the requested behavior",
        inputs: {
          implementation: implementation.payload,
          findings: review.payload.findings,
        },
      },
    };
    implementation = await call(
      input.implementer,
      correctionTask,
      correctionRequest,
      "ImplementationResult",
      [implementationEvidenceId],
    );
    implementationEvidenceId = await runtimeArtifact(
      correctionTask.id,
      await input.runtime.apply({
        taskId: correctionTask.id,
        repositoryId: input.repositoryId,
        revision: input.revision,
        implementation: implementation.payload,
        operations: implementation.payload.proposedOperations,
      }),
    );
    for (const findingId of activeFindingIds) {
      gate.fixFinding(findingId);
      const fixedFinding = gate
        .listFindings(implementationTask.id)
        .find((candidate) => candidate.findingId === findingId);
      if (fixedFinding) await persistFinding(fixedFinding);
    }
    for (const findingId of activeFindingIds) pendingReReviewIds.add(findingId);
  }

  const verificationPhase = await phase(
    "verification",
    "Run real checks and evaluate completion evidence",
    5,
  );
  const testTask = await task(
    verificationPhase.id,
    "Run repository tests and build checks",
    "Verifier",
    ["test_execution"],
    "TestResult",
  );
  const machineEvidence = await input.runtime.test({
    taskId: testTask.id,
    repositoryId: input.repositoryId,
    revision: input.revision,
    changedFiles: implementation.payload.changedFiles,
  });
  const testEvidenceId = await runtimeArtifact(testTask.id, machineEvidence);
  const testRequest: TaskRequest = {
    ...researchRequest,
    messageId: id(),
    workerId: reviewer.worker.id,
    payload: {
      ...researchRequest.payload,
      taskId: testTask.id,
      objective:
        "Interpret the real test evidence against the completion criteria",
      role: "Verifier",
      requiredCapabilities: ["test_execution"],
      contextArtifactIds: [testEvidenceId],
      inputs: { runtimeEvidence: testEvidenceId, revision: input.revision },
    },
  };
  const tests = await call(reviewer, testTask, testRequest, "TestResult", [
    testEvidenceId,
  ]);
  const testVerificationId = id();
  gate.recordVerification({
    verificationId: testVerificationId,
    taskId: implementationTask.id,
    method: "executable_check",
    outcome: tests.payload.outcome === "pass" ? "passed" : "failed",
    verifierWorkerId: reviewer.worker.id,
    independent: true,
  });
  await persistVerification({
    id: testVerificationId,
    runId: input.run.id,
    taskId: implementationTask.id,
    criterionId: "",
    verifierWorkerId: reviewer.worker.id,
    method: "executable_check",
    outcome: tests.payload.outcome === "pass" ? "passed" : "failed",
    evidenceArtifactIds: [testEvidenceId],
    rationale: tests.payload.summary,
    createdAt: now(),
  });
  if (tests.payload.outcome !== "pass")
    throw new Error("Forge executable verification failed");

  const verificationTask = await task(
    verificationPhase.id,
    "Verify all criteria and evidence",
    "Lead",
    ["evaluation"],
    "VerificationResult",
  );
  const criteriaGate = new CompletionCriteriaGate(
    input.goal.completionCriteria,
  );
  const verificationResults: VerificationResult[] = [];
  for (const criterion of input.goal.completionCriteria) {
    const verificationRequest: TaskRequest = {
      ...testRequest,
      messageId: id(),
      workerId: input.lead.worker.id,
      payload: {
        ...testRequest.payload,
        taskId: verificationTask.id,
        objective: `Verify completion criterion ${criterion.id}: ${criterion.description}`,
        role: "Verifier",
        requiredCapabilities: ["evaluation"],
        inputs: {
          reviews: reviews.map((review) => review.payload),
          tests: tests.payload,
          completionCriterion: criterion,
        },
      },
    };
    const verification = await call(
      input.lead,
      verificationTask,
      verificationRequest,
      "VerificationResult",
      [testEvidenceId, implementationEvidenceId],
    );
    const criterionVerificationId = id();
    criteriaGate.recordVerification({
      criterionId: verification.payload.criterionId,
      method: verification.payload.method,
      outcome: verification.payload.outcome,
      verificationId: criterionVerificationId,
      verifierWorkerId: input.lead.worker.id,
      evidenceArtifactIds: [testEvidenceId, implementationEvidenceId],
    });
    await persistVerification({
      id: criterionVerificationId,
      runId: input.run.id,
      taskId: verificationTask.id,
      criterionId: verification.payload.criterionId,
      verifierWorkerId: input.lead.worker.id,
      method: verification.payload.method,
      outcome: verification.payload.outcome,
      evidenceArtifactIds: [testEvidenceId, implementationEvidenceId],
      rationale: verification.payload.rationale,
      createdAt: now(),
    });
    verificationResults.push(verification);
  }
  criteriaGate.assertAllVerified();
  if (!gate.canComplete(implementationTask.id))
    throw new Error("Forge verification gate did not pass");

  const reportingPhase = await phase(
    "reporting",
    "Produce the final completion report",
    6,
  );
  const completionTask = await task(
    reportingPhase.id,
    "Report the verified result",
    "Lead",
    ["evaluation"],
    "CompletionResult",
  );
  const completionRequest: TaskRequest = {
    ...testRequest,
    messageId: id(),
    workerId: input.lead.worker.id,
    payload: {
      ...testRequest.payload,
      taskId: completionTask.id,
      objective: "Produce the final verified completion report",
      inputs: {
        verifications: verificationResults.map((result) => result.payload),
        implementation: implementation.payload,
        reviews: reviews.map((review) => review.payload),
        tests: tests.payload,
      },
    },
  };
  const completion = await call(
    input.lead,
    completionTask,
    completionRequest,
    "CompletionResult",
    [testEvidenceId, implementationEvidenceId],
  );
  criteriaGate.assertCompletionClaim(completion.payload.criteria);
  if (
    completion.payload.outcome !== "completed" ||
    completion.payload.unresolvedFindingIds.length > 0
  ) {
    throw new Error("Forge completion report is not verified");
  }
  await artifact(
    completionTask.id,
    JSON.stringify({
      completion: completion.payload,
      machineEvidence,
      interpretedTestResult: tests.payload,
    }),
    "application/json",
    { kind: "completion_report", workerId: input.lead.worker.id },
  );
  await event("RunCompleted", "run", input.run.id, {
    outcome: completion.payload.outcome,
    correctionLoops,
  });
  return {
    research,
    secondaryResearch,
    plan,
    implementation,
    reviews,
    tests,
    machineEvidence,
    verification: verificationResults,
    completion,
    correctionLoops,
  };
}
