import type {
  ArtifactRecord,
  AttemptRecord,
  GoalRecord,
  JsonValue,
  ModelCallRecord,
  PhaseRecord,
  RunEventRecord,
  RunRecord,
  TaskRecord,
} from "@conclave/persistence";
import { validateTaskGraph } from "@conclave/core";
import type { ModelResponse, ModelWorker } from "@conclave/providers";
import {
  parseModelResult,
  type CompletionResult,
  type ModelResult,
  type PlanRequest,
  type PlanResult,
  type TaskRequest,
  type TaskResult,
} from "@conclave/protocol";

export interface MvpPersistence {
  saveGoal(goal: GoalRecord): Promise<void>;
  saveRun(run: RunRecord): Promise<void>;
  savePhase(phase: PhaseRecord): Promise<void>;
  saveTask(task: TaskRecord): Promise<void>;
  saveAttempt(attempt: AttemptRecord): Promise<void>;
  saveModelCall(call: ModelCallRecord): Promise<void>;
  saveArtifact(artifact: ArtifactRecord): Promise<void>;
  appendEvent(event: RunEventRecord): Promise<void>;
}

export interface TwoModelGoalInput {
  readonly goal: GoalRecord;
  readonly run: RunRecord;
  readonly repositoryId: string;
  readonly revision: string;
  readonly lead: ModelWorker;
  readonly specialist: ModelWorker;
  readonly persistence: MvpPersistence;
  readonly idFactory?: () => string;
  readonly now?: () => string;
}

export interface TwoModelGoalResult {
  readonly plan: PlanResult;
  readonly specialistResult: TaskResult;
  readonly completion: CompletionResult;
}

export class InMemoryMvpPersistence implements MvpPersistence {
  readonly goals: GoalRecord[] = [];
  readonly runs: RunRecord[] = [];
  readonly phases: PhaseRecord[] = [];
  readonly tasks: TaskRecord[] = [];
  readonly attempts: AttemptRecord[] = [];
  readonly modelCalls: ModelCallRecord[] = [];
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

  saveAttempt(attempt: AttemptRecord): Promise<void> {
    this.attempts.push(attempt);
    return Promise.resolve();
  }

  saveModelCall(call: ModelCallRecord): Promise<void> {
    this.modelCalls.push(call);
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
}

function defaultId(): string {
  return crypto.randomUUID();
}

function jsonObject(value: unknown): JsonValue {
  return JSON.parse(JSON.stringify(value)) as JsonValue;
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function persistArtifact(
  persistence: MvpPersistence,
  id: string,
  runId: string,
  taskId: string,
  attemptId: string | null,
  content: string,
  mediaType: string,
  provenance: JsonValue,
  createdAt: string,
): Promise<string> {
  await persistence.saveArtifact({
    id,
    runId,
    taskId,
    attemptId,
    mediaType,
    payload: { kind: "inline", content },
    contentDigest: await sha256(content),
    sizeBytes: new TextEncoder().encode(content).byteLength,
    provenance,
    createdAt,
  });
  return id;
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

export async function executeTwoModelGoal(
  input: TwoModelGoalInput,
): Promise<TwoModelGoalResult> {
  const id = input.idFactory ?? defaultId;
  const now = input.now ?? (() => new Date().toISOString());
  const persistence = input.persistence;
  let sequence = 0;

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

  await persistence.saveGoal(input.goal);
  await persistence.saveRun(input.run);
  await event("GoalReceived", "goal", input.goal.id, {
    objective: input.goal.objective,
  });
  await event("RunStarted", "run", input.run.id, { status: input.run.status });

  const phase: PhaseRecord = {
    id: id(),
    runId: input.run.id,
    name: "two-model-mvp",
    purpose: "Lead delegates one task to a Specialist and evaluates the result",
    sequence: 1,
    status: "active",
    createdAt: now(),
    updatedAt: now(),
  };
  await persistence.savePhase(phase);

  const planTaskId = id();
  const planTask: TaskRecord = {
    id: planTaskId,
    phaseId: phase.id,
    objective: "Create one delegated task for the goal",
    role: "Lead",
    capabilities: ["planning"],
    input: { goalId: input.goal.id },
    outputContract: { messageType: "PlanResult" },
    status: "running",
    requiresIndependentVerification: false,
    createdAt: now(),
    updatedAt: now(),
  };
  await persistence.saveTask(planTask);

  const call = async <T extends ModelResult["messageType"]>(
    worker: ModelWorker,
    task: TaskRecord,
    request: PlanRequest | TaskRequest,
    expected: T,
  ): Promise<Extract<ModelResult, { messageType: T }>> => {
    const attemptId = id();
    const startedAt = now();
    const requestArtifactId = await persistArtifact(
      persistence,
      id(),
      input.run.id,
      task.id,
      attemptId,
      JSON.stringify(request),
      "application/json",
      {
        kind: "protocol_request",
        messageType: request.messageType,
        workerId: worker.resource.id,
      },
      startedAt,
    );
    await event("ModelRequestPersisted", "attempt", attemptId, {
      messageType: request.messageType,
      workerId: worker.resource.id,
    });
    await persistence.saveAttempt({
      id: attemptId,
      taskId: task.id,
      workerId: worker.resource.id,
      attemptNumber: 1,
      inputSnapshot: jsonObject(request),
      outputArtifactIds: [requestArtifactId],
      status: "running",
      failureClass: null,
      startedAt,
      finishedAt: null,
    });

    let response: ModelResponse;
    try {
      response = await worker.complete({ message: request });
    } catch (error) {
      await persistence.saveAttempt({
        id: attemptId,
        taskId: task.id,
        workerId: worker.resource.id,
        attemptNumber: 1,
        inputSnapshot: jsonObject(request),
        outputArtifactIds: [requestArtifactId],
        status: "errored",
        failureClass: "worker",
        startedAt,
        finishedAt: now(),
      });
      await event("ModelCallFailed", "attempt", attemptId, {
        messageType: request.messageType,
        reason: error instanceof Error ? error.message : "unknown",
      });
      throw error;
    }

    const responseArtifactId = await persistArtifact(
      persistence,
      id(),
      input.run.id,
      task.id,
      attemptId,
      response.rawResponse,
      "application/json",
      {
        kind: "provider_response",
        provider: worker.resource.provider,
        providerRequestId: response.providerRequestId,
      },
      now(),
    );
    await persistence.saveModelCall({
      id: id(),
      attemptId,
      workerId: worker.resource.id,
      provider: worker.resource.provider,
      model: worker.resource.name,
      requestArtifactId,
      responseArtifactId,
      status: "completed",
      inputTokens: response.usage.inputTokens,
      outputTokens: response.usage.outputTokens,
      startedAt,
      finishedAt: now(),
    });

    let result: ModelResult;
    let accepted: Extract<ModelResult, { messageType: T }>;
    try {
      result = parseModelResult(JSON.parse(response.text) as unknown);
      accepted = expectedResult(result, expected);
    } catch (error) {
      await persistence.saveAttempt({
        id: attemptId,
        taskId: task.id,
        workerId: worker.resource.id,
        attemptNumber: 1,
        inputSnapshot: jsonObject(request),
        outputArtifactIds: [requestArtifactId, responseArtifactId],
        status: "rejected",
        failureClass: "validation",
        startedAt,
        finishedAt: now(),
      });
      await event("ModelResultRejected", "attempt", attemptId, {
        messageType: request.messageType,
        reason: error instanceof Error ? error.message : "unknown",
      });
      throw error;
    }

    await persistence.saveAttempt({
      id: attemptId,
      taskId: task.id,
      workerId: worker.resource.id,
      attemptNumber: 1,
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
  };

  const planRequest: PlanRequest = {
    protocol: "conclave.protocol",
    version: "0.1",
    messageId: id(),
    goalId: input.goal.id,
    runId: input.run.id,
    workerId: input.lead.resource.id,
    createdAt: now(),
    messageType: "PlanRequest",
    payload: {
      objective: input.goal.objective,
      constraints: [...input.goal.constraints],
      repository: {
        repositoryId: input.repositoryId,
        revision: input.revision,
      },
      completionCriteria: [...input.goal.completionCriteria],
    },
  };
  const plan = await call(input.lead, planTask, planRequest, "PlanResult");
  const validatedGraph = validateTaskGraph(plan);
  const delegated = validatedGraph.tasks[0];
  if (delegated === undefined)
    throw new Error("Lead returned no delegated task");

  const specialistTask: TaskRecord = {
    id: delegated.taskId,
    phaseId: phase.id,
    objective: delegated.objective,
    role: delegated.role,
    capabilities: delegated.capabilities,
    input: { plan: jsonObject(plan.payload) },
    outputContract: { messageType: "TaskResult" },
    status: "running",
    requiresIndependentVerification: delegated.requiresIndependentVerification,
    createdAt: now(),
    updatedAt: now(),
  };
  await persistence.saveTask(specialistTask);

  const taskRequest: TaskRequest = {
    protocol: "conclave.protocol",
    version: "0.1",
    messageId: id(),
    goalId: input.goal.id,
    runId: input.run.id,
    workerId: input.specialist.resource.id,
    createdAt: now(),
    messageType: "TaskRequest",
    payload: {
      taskId: delegated.taskId,
      objective: delegated.objective,
      role: delegated.role,
      requiredCapabilities: [...delegated.capabilities],
      contextArtifactIds: [],
      inputs: { plan: plan.payload },
    },
  };
  const specialistResult = await call(
    input.specialist,
    specialistTask,
    taskRequest,
    "TaskResult",
  );

  const evaluationTask: TaskRecord = {
    id: id(),
    phaseId: phase.id,
    objective:
      "Evaluate the Specialist result and decide whether the goal is complete",
    role: "Lead",
    capabilities: ["evaluation"],
    input: { specialistResult: jsonObject(specialistResult.payload) },
    outputContract: { messageType: "CompletionResult" },
    status: "running",
    requiresIndependentVerification: false,
    createdAt: now(),
    updatedAt: now(),
  };
  await persistence.saveTask(evaluationTask);

  const evaluationRequest: TaskRequest = {
    protocol: "conclave.protocol",
    version: "0.1",
    messageId: id(),
    goalId: input.goal.id,
    runId: input.run.id,
    workerId: input.lead.resource.id,
    createdAt: now(),
    messageType: "TaskRequest",
    payload: {
      taskId: evaluationTask.id,
      objective: evaluationTask.objective,
      role: "Lead",
      requiredCapabilities: ["evaluation"],
      contextArtifactIds: [],
      inputs: { specialistResult: specialistResult.payload },
    },
  };
  const completion = await call(
    input.lead,
    evaluationTask,
    evaluationRequest,
    "CompletionResult",
  );
  await persistArtifact(
    persistence,
    completion.payload.finalReportArtifactId,
    input.run.id,
    evaluationTask.id,
    null,
    JSON.stringify(completion.payload),
    "application/json",
    { kind: "completion_report", workerId: input.lead.resource.id },
    now(),
  );
  await event(
    "CompletionReportPersisted",
    "artifact",
    completion.payload.finalReportArtifactId,
    {
      messageType: completion.messageType,
    },
  );
  await event("RunCompleted", "run", input.run.id, {
    outcome: completion.payload.outcome,
  });
  return { plan, specialistResult, completion };
}
