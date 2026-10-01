import {
  WorkflowEntrypoint,
  type WorkflowEvent,
  type WorkflowStep,
} from "cloudflare:workers";
import {
  parseMachineCheckEvidence,
  type MachineCheckEvidence,
} from "@conclave/protocol";
import {
  markWorkflowTaskResult,
  planWorkflowTasks,
  readyWorkflowTasks,
  validateBuiltinWorkflowDefinition,
  type PlannedWorkflowTask,
  type BuiltinWorkflowDefinition,
  type StepKind,
  type StepResult,
  type WorkRequestSnapshot,
} from "@conclave/core";
import {
  renderWorkStepPrompt,
  workStepPromptInputs,
} from "./workflow-prompts.js";
import { createEventPublisher } from "./event-publisher.js";

export interface ConclaveWorkflowParams {
  readonly runId: string;
  readonly goalId: string;
  readonly idempotencyKey: string;
  readonly organizationId?: string;
  readonly repositoryId?: string;
  readonly revision?: string;
  readonly expectedCommitSha?: string;
  readonly expectedChecks?: readonly string[];
  readonly allowedWorkflows?: readonly string[];
  readonly requireApproval?: boolean;
  readonly requireCiEvidence?: boolean;
  readonly startPaused?: boolean;
  /** Defaults to the local single-worker path; cloud API workers are opt-in. */
  readonly executionMode?: "single_worker" | "multi_worker";
  /** Immutable Work v1 catalog definition. When present, the fixed-step runner is used. */
  readonly builtinWorkflow?: BuiltinWorkflowDefinition;
  readonly workRequestId?: string;
  readonly workstreamId?: string;
  readonly projectId?: string;
  readonly input?: Record<string, unknown>;
  readonly retryStepKind?: StepKind;
  readonly retrySessionStrategy?: "resume" | "fresh";
  readonly retryNumber?: number;
}

export interface ConclaveWorkflowCheckpoint {
  readonly runId: string;
  readonly goalId: string;
  readonly idempotencyKey: string;
  readonly stage:
    | "workflow"
    | "intake"
    | "research"
    | "planning"
    | "implementation"
    | "verification"
    | "completed"
    | "cancelled"
    | "failed"
    | "needs_input";
  readonly status: "active" | "waiting" | "completed" | "cancelled" | "failed";
  readonly eventId?: string;
  readonly eventAction?: string;
  readonly machineEvidence?: Pick<
    MachineCheckEvidence,
    | "evidenceId"
    | "source"
    | "externalRunId"
    | "runId"
    | "repositoryId"
    | "commitSha"
    | "workflow"
    | "conclusion"
    | "checks"
    | "coveragePercent"
    | "previewUrl"
    | "smokeTests"
    | "healthChecks"
    | "observedAt"
  >;
  readonly executionId?: string;
  readonly executionStatus?:
    "started" | "completed" | "failed" | "cancelled" | "needs_input";
  readonly resultArtifactId?: string;
  readonly failureReason?: string;
  readonly workflowStepId?: string;
}

interface ForgeExecutionService {
  fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response>;
}

type ExecutionEnv = Env & {
  readonly CONCLAVE_FORGE_EXECUTION?: ForgeExecutionService;
  readonly CONCLAVE_WORKSTREAM_COORDINATOR?: DurableObjectNamespace;
};

interface RunControlEvent {
  readonly eventId: string;
  readonly action: "continue" | "cancel";
}

interface ApprovalEvent {
  readonly eventId: string;
  readonly approved: boolean;
}

type MachineEvidenceEvent = MachineCheckEvidence;

interface ForgeTerminalEvent {
  readonly eventId: string;
  readonly runId: string;
  readonly executionId: string;
  readonly status: "completed" | "failed" | "cancelled" | "needs_input";
  readonly resultArtifactId?: string;
  readonly finalText?: string;
  readonly workerId?: string | null;
  readonly workerTypeId?: string | null;
  readonly engineVersion?: string | null;
  readonly profileDefinitionId?: string | null;
  readonly profileReleaseVersion?: number | null;
  readonly providerToolVersion?: string | null;
  readonly model?: string | null;
  readonly error?: string;
}

interface ForgeExecutionStatus {
  readonly executionId: string;
  readonly runId: string;
  readonly status:
    "started" | "completed" | "failed" | "cancelled" | "needs_input";
  readonly resultArtifactId?: string;
  readonly error?: string;
}

const stepConfig = {
  retries: {
    limit: 3,
    delay: "5 seconds" as const,
    backoff: "exponential" as const,
  },
  timeout: "5 minutes" as const,
} as const;

function isRunControlEvent(value: unknown): value is RunControlEvent {
  if (typeof value !== "object" || value === null) return false;
  const record = value as Record<string, unknown>;
  return (
    typeof record.eventId === "string" &&
    (record.action === "continue" || record.action === "cancel")
  );
}

function isApprovalEvent(value: unknown): value is ApprovalEvent {
  if (typeof value !== "object" || value === null) return false;
  const record = value as Record<string, unknown>;
  return (
    typeof record.eventId === "string" && typeof record.approved === "boolean"
  );
}

function isForgeTerminalEvent(value: unknown): value is ForgeTerminalEvent {
  if (typeof value !== "object" || value === null) return false;
  const record = value as Record<string, unknown>;
  return (
    typeof record.eventId === "string" &&
    typeof record.runId === "string" &&
    typeof record.executionId === "string" &&
    (record.status === "completed" ||
      record.status === "failed" ||
      record.status === "cancelled" ||
      record.status === "needs_input") &&
    (record.resultArtifactId === undefined ||
      typeof record.resultArtifactId === "string") &&
    (record.finalText === undefined || typeof record.finalText === "string") &&
    (record.workerId === undefined ||
      record.workerId === null ||
      typeof record.workerId === "string") &&
    (record.workerTypeId === undefined ||
      record.workerTypeId === null ||
      typeof record.workerTypeId === "string") &&
    (record.engineVersion === undefined ||
      record.engineVersion === null ||
      typeof record.engineVersion === "string") &&
    (record.profileDefinitionId === undefined ||
      record.profileDefinitionId === null ||
      typeof record.profileDefinitionId === "string") &&
    (record.profileReleaseVersion === undefined ||
      record.profileReleaseVersion === null ||
      (Number.isSafeInteger(record.profileReleaseVersion) &&
        Number(record.profileReleaseVersion) > 0)) &&
    (record.providerToolVersion === undefined ||
      record.providerToolVersion === null ||
      typeof record.providerToolVersion === "string") &&
    (record.model === undefined ||
      record.model === null ||
      typeof record.model === "string") &&
    (record.error === undefined || typeof record.error === "string")
  );
}

function isForgeExecutionStatus(value: unknown): value is ForgeExecutionStatus {
  if (typeof value !== "object" || value === null) return false;
  const record = value as Record<string, unknown>;
  return (
    typeof record.executionId === "string" &&
    typeof record.runId === "string" &&
    (record.status === "started" ||
      record.status === "completed" ||
      record.status === "failed" ||
      record.status === "cancelled" ||
      record.status === "needs_input") &&
    (record.resultArtifactId === undefined ||
      typeof record.resultArtifactId === "string") &&
    (record.error === undefined || typeof record.error === "string")
  );
}

function parseWorkflowStepResult(value: unknown): StepResult | null {
  if (typeof value !== "string") return null;
  try {
    const parsed: unknown = JSON.parse(value);
    if (
      typeof parsed !== "object" ||
      parsed === null ||
      Array.isArray(parsed)
    ) {
      return null;
    }
    const result = parsed as Partial<StepResult>;
    return result.status === "completed" && typeof result.text === "string"
      ? (result as StepResult)
      : null;
  } catch {
    return null;
  }
}

function validateMachineEvidence(
  evidence: MachineEvidenceEvent,
  params: ConclaveWorkflowParams,
): void {
  if (evidence.runId !== params.runId)
    throw new Error("CI evidence does not belong to this run");
  if (!params.repositoryId || evidence.repositoryId !== params.repositoryId)
    throw new Error("CI evidence repository does not match this run");
  if (
    !params.expectedCommitSha ||
    evidence.commitSha !== params.expectedCommitSha
  )
    throw new Error("CI evidence commit SHA does not match this run");
  if (
    params.allowedWorkflows &&
    !params.allowedWorkflows.includes(evidence.workflow)
  )
    throw new Error("CI workflow is not allowed for this run");
  const checkNames = new Set(evidence.checks.map((check) => check.name));
  for (const expectedCheck of params.expectedChecks ?? []) {
    if (!checkNames.has(expectedCheck))
      throw new Error(`Expected CI check is missing: ${expectedCheck}`);
  }
}

export class ConclaveRunWorkflow extends WorkflowEntrypoint<
  Env,
  ConclaveWorkflowParams
> {
  private async persistTerminalRun(
    runId: string,
    status: "completed" | "failed" | "cancelled",
  ): Promise<void> {
    const db = (this.env as ExecutionEnv).CONCLAVE_DB;
    if (!db) return;
    const now = new Date().toISOString();
    await db
      .prepare(
        "UPDATE runs SET status = ?1, finished_at = ?2, updated_at = ?2 WHERE id = ?3",
      )
      .bind(status, now, runId)
      .run();
    await db
      .prepare(
        "UPDATE run_external_executions SET status = ?1, updated_at = ?2 WHERE run_id = ?3 AND execution_kind = 'cloudflare_workflow'",
      )
      .bind(status, now, runId)
      .run();
  }

  private async finishWorkRequest(
    params: ConclaveWorkflowParams,
    status: "completed" | "failed" | "cancelled",
  ): Promise<void> {
    if (!params.workRequestId || !params.workstreamId) return;
    const runtimeEnv = this.env as ExecutionEnv;
    const db = runtimeEnv.CONCLAVE_DB;
    const namespace = runtimeEnv.CONCLAVE_WORKSTREAM_COORDINATOR;
    if (!db) return;
    const request = await db
      .prepare(
        "SELECT mode FROM work_requests WHERE id = ?1 AND workstream_id = ?2",
      )
      .bind(params.workRequestId, params.workstreamId)
      .first<{ mode: string }>();
    if (request?.mode === "stateless") {
      const now = new Date().toISOString();
      await db
        .prepare(
          "UPDATE work_requests SET status = ?1, updated_at = ?2 WHERE id = ?3 AND status IN ('queued', 'running')",
        )
        .bind(status, now, params.workRequestId)
        .run();
      return;
    }
    if (!namespace) return;
    const lease = await db
      .prepare(
        `SELECT id, fencing_token AS fencingToken FROM workstream_runtime_leases
       WHERE work_request_id = ?1 AND workstream_id = ?2 AND status = 'active' LIMIT 1`,
      )
      .bind(params.workRequestId, params.workstreamId)
      .first<{ id: string; fencingToken: number }>();
    if (!lease) return;
    const stub = namespace.getByName(params.workstreamId);
    await stub.fetch("https://workstream-coordinator/complete", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-workstream-id": params.workstreamId,
      },
      body: JSON.stringify({
        workRequestId: params.workRequestId,
        leaseId: lease.id,
        fencingToken: lease.fencingToken,
        status,
      }),
    });
  }

  private async persistWorkflowTasks(
    params: ConclaveWorkflowParams,
    tasks: readonly PlannedWorkflowTask[],
  ): Promise<void> {
    const db = (this.env as ExecutionEnv).CONCLAVE_DB;
    if (!db || !params.workRequestId) return;
    const now = new Date().toISOString();
    const statements = tasks.flatMap((task) => [
      db
        .prepare(
          `INSERT INTO workflow_tasks
         (id, work_request_id, step_kind, execution_mode,
          timeout_ms, prompt_profile_version,
          status, attempt, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'queued', 0, ?7, ?7)
         ON CONFLICT(work_request_id, step_kind) DO NOTHING`,
        )
        .bind(
          task.id,
          task.workRequestId,
          task.step.kind,
          task.step.executionMode,
          task.step.timeoutMs,
          task.step.promptProfileVersion,
          now,
        ),
      ...task.dependencyTaskIds.map((dependencyId) =>
        db
          .prepare(
            `INSERT INTO workflow_task_dependencies (task_id, depends_on_task_id)
           VALUES (?1, ?2) ON CONFLICT(task_id, depends_on_task_id) DO NOTHING`,
          )
          .bind(task.id, dependencyId),
      ),
    ]);
    if (statements.length > 0) await db.batch(statements);
  }

  private async publishWorkEvent(
    params: ConclaveWorkflowParams,
    type:
      | "work_request.started"
      | "work_request.completed"
      | "work_request.failed"
      | "work_request.cancelled"
      | "step.queued"
      | "step.running"
      | "step.completed"
      | "step.failed"
      | "step.cancelled",
    options: { status: string; stepKind?: StepKind; attempt?: number },
  ): Promise<void> {
    const workRequestId = params.workRequestId;
    const workstreamId = params.workstreamId;
    const workspaceId = params.organizationId;
    if (!workRequestId || !workstreamId || !workspaceId) return;
    try {
      const projectId =
        params.projectId ??
        (
          await (this.env as ExecutionEnv).CONCLAVE_DB.prepare(
            "SELECT project_id AS projectId FROM workstreams WHERE id = ?1",
          )
            .bind(workstreamId)
            .first<{ projectId: string }>()
        )?.projectId;
      if (!projectId) return;
      const stepSuffix = options.stepKind ? `:step:${options.stepKind}` : "";
      const attemptSuffix = options.attempt
        ? `:attempt:${options.attempt}`
        : "";
      await createEventPublisher(this.env).publish({
        type,
        workspaceId,
        projectId,
        runId: params.runId,
        idempotencyKey: `work-request:${workRequestId}:${type}${stepSuffix}${attemptSuffix}`,
        payload: {
          entityId: options.stepKind ?? workRequestId,
          workRequestId,
          workstreamId,
          ...(options.stepKind ? { stepKind: options.stepKind } : {}),
          status: options.status,
        },
      });
    } catch (error) {
      console.error(`Failed to publish ${type}`, error);
    }
  }

  private async persistWorkflowTaskState(
    task: PlannedWorkflowTask,
    output?: unknown,
    error?: string,
    status: PlannedWorkflowTask["status"] = task.status,
    attempt: number = task.attempt,
  ): Promise<void> {
    const db = (this.env as ExecutionEnv).CONCLAVE_DB;
    if (!db) return;
    await db
      .prepare(
        `UPDATE workflow_tasks SET status = ?1, attempt = ?2, output_json = ?3,
       error = ?4, updated_at = ?5,
       started_at = CASE WHEN ?1 = 'running' THEN COALESCE(started_at, ?5) ELSE started_at END,
       finished_at = CASE WHEN ?1 IN ('completed', 'failed', 'cancelled') THEN ?5 ELSE finished_at END
       WHERE id = ?6`,
      )
      .bind(
        status,
        attempt,
        output === undefined ? null : JSON.stringify(output),
        error ?? null,
        new Date().toISOString(),
        task.id,
      )
      .run();
  }

  private async runVersioned(
    params: ConclaveWorkflowParams,
    step: WorkflowStep,
  ): Promise<ConclaveWorkflowCheckpoint> {
    const definition = params.builtinWorkflow!;
    validateBuiltinWorkflowDefinition(definition);
    const workRequestId = params.workRequestId ?? `run-${params.runId}`;
    const promptInput = await this.loadWorkRequestPromptInput(params);
    let tasks = [...planWorkflowTasks(definition, workRequestId)];
    const stepResults: Partial<Record<StepKind, StepResult>> = {};
    const db = (this.env as ExecutionEnv).CONCLAVE_DB;
    if (db && params.workRequestId) {
      const requestMode = await db
        .prepare("SELECT mode FROM work_requests WHERE id = ?1")
        .bind(params.workRequestId)
        .first<{ mode: string }>();
      if (requestMode?.mode === "stateless") {
        const now = new Date().toISOString();
        await db.batch([
          db
            .prepare(
              "UPDATE work_requests SET status = 'running', updated_at = ?1 WHERE id = ?2 AND status = 'queued'",
            )
            .bind(now, params.workRequestId),
          db
            .prepare(
              "UPDATE runs SET status = 'running', updated_at = ?1 WHERE work_request_id = ?2 AND status = 'created'",
            )
            .bind(now, params.workRequestId),
        ]);
      }
    }
    await this.persistWorkflowTasks(params, tasks);
    if (params.retryStepKind && db && params.workRequestId) {
      const persistedRows = await db
        .prepare(
          `SELECT step_kind AS kind, status, attempt, output_json AS outputJson
           FROM workflow_tasks WHERE work_request_id = ?1`,
        )
        .bind(params.workRequestId)
        .all<Record<string, unknown>>();
      const persistedByKind = new Map(
        (persistedRows.results ?? []).map((row) => [String(row.kind), row]),
      );
      tasks = tasks.map((task) => {
        const persisted = persistedByKind.get(task.step.kind);
        if (persisted?.status !== "completed") return task;
        const output = parseWorkflowStepResult(persisted.outputJson);
        if (!output) {
          throw new Error(
            `Completed ${task.step.kind} result is unavailable for retry`,
          );
        }
        stepResults[task.step.kind] = output;
        return {
          ...task,
          status: "completed",
          attempt:
            typeof persisted.attempt === "number" ? persisted.attempt : 0,
        };
      });
    }
    await this.publishWorkEvent(params, "work_request.started", {
      status: "running",
    });
    await Promise.all(
      tasks
        .filter((task) => task.status === "queued")
        .map((task) =>
          this.publishWorkEvent(params, "step.queued", {
            stepKind: task.step.kind,
            status: "queued",
          }),
        ),
    );
    const started: ConclaveWorkflowCheckpoint = {
      runId: params.runId,
      goalId: params.goalId,
      idempotencyKey: params.idempotencyKey,
      stage: "workflow",
      status: "active",
    };

    while (true) {
      const ready = readyWorkflowTasks(tasks);
      if (ready.length === 0) {
        if (tasks.every((task) => task.status === "completed")) break;
        const failed = tasks.find(
          (task) => task.status === "failed" || task.status === "cancelled",
        );
        const status = failed?.status === "cancelled" ? "cancelled" : "failed";
        await this.persistTerminalRun(params.runId, status);
        await this.finishWorkRequest(params, status);
        if (status === "failed") {
          await this.publishWorkEvent(params, "work_request.failed", {
            status: "failed",
          });
        }
        return {
          ...started,
          stage: status,
          status,
          workflowStepId: failed?.step.kind,
          failureReason: failed
            ? `Workflow step ${failed.step.kind} ${failed.status}`
            : "Workflow has no runnable steps",
        };
      }
      // Stateful Workstream steps are never concurrent. Independent stateless
      // steps can share one durable Workflow batch.
      const batch = ready.some(
        (task) => task.step.executionMode === "stateful_workstream",
      )
        ? [
            ready.find(
              (task) => task.step.executionMode === "stateful_workstream",
            )!,
          ]
        : ready;
      const results = await Promise.all(
        batch.map((task) =>
          this.runWorkflowTask(
            params,
            definition,
            task,
            promptInput,
            step,
            stepResults,
          ),
        ),
      );
      for (const result of results) {
        const cancellationRequested = await (
          this.env as ExecutionEnv
        ).CONCLAVE_DB.prepare(
          "SELECT cancel_requested_at AS cancelRequestedAt FROM work_requests WHERE id = ?1",
        )
          .bind(params.workRequestId)
          .first<{ cancelRequestedAt: string | null }>();
        const resultStatus = cancellationRequested?.cancelRequestedAt
          ? "cancelled"
          : result.status;
        if (resultStatus === "completed" && result.stepResult) {
          stepResults[result.task.step.kind] = result.stepResult;
        }
        tasks = [
          ...markWorkflowTaskResult(tasks, result.task.id, resultStatus),
        ];
        const persistedTask = tasks.find((task) => task.id === result.task.id)!;
        await this.persistWorkflowTaskState(
          persistedTask,
          result.output,
          result.error,
        );
        if (resultStatus === "completed" || resultStatus === "failed") {
          await this.publishWorkEvent(
            params,
            resultStatus === "completed" ? "step.completed" : "step.failed",
            { stepKind: result.task.step.kind, status: resultStatus },
          );
        }
        if (resultStatus === "failed" || resultStatus === "cancelled") {
          const failed = tasks.find(
            (candidate) => candidate.id === result.task.id,
          )!;
          await this.persistTerminalRun(params.runId, resultStatus);
          await this.finishWorkRequest(params, resultStatus);
          if (resultStatus === "failed") {
            await this.publishWorkEvent(params, "work_request.failed", {
              status: "failed",
            });
          } else {
            await this.publishWorkEvent(params, "step.cancelled", {
              stepKind: result.task.step.kind,
              status: "cancelled",
            });
            await this.publishWorkEvent(params, "work_request.cancelled", {
              stepKind: result.task.step.kind,
              status: "cancelled",
            });
          }
          return {
            ...started,
            stage: resultStatus,
            status: resultStatus,
            workflowStepId: failed.step.kind,
            failureReason:
              result.error ??
              `Workflow step ${failed.step.kind} ${resultStatus}`,
          };
        }
      }
    }
    await this.persistTerminalRun(params.runId, "completed");
    await this.finishWorkRequest(params, "completed");
    await this.publishWorkEvent(params, "work_request.completed", {
      status: "completed",
    });
    return { ...started, stage: "completed", status: "completed" };
  }

  private async runWorkflowTask(
    params: ConclaveWorkflowParams,
    definition: BuiltinWorkflowDefinition,
    task: PlannedWorkflowTask,
    promptInput: Record<string, unknown>,
    workflowStep: WorkflowStep,
    stepResults: Partial<Record<StepKind, StepResult>>,
  ): Promise<{
    task: PlannedWorkflowTask;
    status: "completed" | "failed" | "cancelled";
    output?: unknown;
    stepResult?: StepResult;
    error?: string;
  }> {
    const service = (this.env as ExecutionEnv).CONCLAVE_FORGE_EXECUTION;
    if (!service)
      return {
        task,
        status: "failed",
        error: "Forge execution service is not configured",
      };
    let attempt = 0;
    const startedAt = new Date().toISOString();
    while (attempt < 3) {
      attempt += 1;
      await this.persistWorkflowTaskState(
        task,
        undefined,
        undefined,
        "running",
        attempt,
      );
      await this.publishWorkEvent(params, "step.running", {
        stepKind: task.step.kind,
        attempt,
        status: "running",
      });
      try {
        const execution = await workflowStep.do(
          `workflow:${task.step.kind}:execute:${attempt}`,
          {
            ...stepConfig,
            timeout:
              `${Math.max(1, Math.ceil(task.step.timeoutMs / 1000))} seconds` as `${number} seconds`,
          },
          async () => {
            const workBindingId =
              definition.id === "direct" ? "direct" : task.step.kind;
            const promptInputs = workStepPromptInputs(
              { ...promptInput, workRequestId: params.workRequestId },
              stepResults,
            );
            const workConfig =
              typeof promptInput.workConfig === "object" &&
              promptInput.workConfig !== null
                ? (promptInput.workConfig as Record<string, unknown>)
                : {};
            const bindings =
              typeof workConfig.bindings === "object" &&
              workConfig.bindings !== null
                ? (workConfig.bindings as Record<string, unknown>)
                : {};
            const stepBinding =
              typeof bindings[workBindingId] === "object" &&
              bindings[workBindingId] !== null
                ? (bindings[workBindingId] as Record<string, unknown>)
                : {};
            const configuredInstructions =
              typeof stepBinding.additionalInstructions === "string"
                ? stepBinding.additionalInstructions
                : "";
            const requestInstructions =
              promptInputs.stepInstructions?.[task.step.kind] ?? "";
            const mergedInstructions = [
              requestInstructions,
              configuredInstructions,
            ]
              .filter((value) => value.trim().length > 0)
              .join("\n\n");
            const prompt = renderWorkStepPrompt(definition, task.step, {
              ...promptInputs,
              stepInstructions: {
                ...promptInputs.stepInstructions,
                ...(mergedInstructions
                  ? { [task.step.kind]: mergedInstructions }
                  : {}),
              },
            });
            const {
              workConfig: _workConfig,
              workRequestSnapshot: _workRequestSnapshot,
              ...workerInput
            } = promptInput;
            const response = await service.fetch(
              "https://conclave.internal/execute",
              {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({
                  ...params,
                  workflowStep: task.step,
                  workBindingId,
                  effectiveWorkerPrompt: prompt,
                  input: {
                    ...workerInput,
                    effectiveWorkerPrompt: prompt,
                  },
                }),
              },
            );
            if (!response.ok)
              throw new Error(
                `Workflow step dispatch failed with status ${response.status}`,
              );
            const body = (await response.json()) as { executionId?: unknown };
            if (typeof body.executionId !== "string")
              throw new Error("Workflow step returned no executionId");
            return body.executionId;
          },
        );
        const terminal = await workflowStep.waitForEvent<ForgeTerminalEvent>(
          `workflow:${task.step.kind}:terminal:${attempt}`,
          {
            type: "forge-terminal",
            timeout: `${Math.ceil(task.step.timeoutMs / 60_000) + 1} minutes`,
          },
        );
        if (
          !isForgeTerminalEvent(terminal.payload) ||
          terminal.payload.runId !== params.runId ||
          terminal.payload.executionId !== execution
        ) {
          return {
            task,
            status: "failed",
            error: "Workflow step terminal result correlation failed",
          };
        }
        if (terminal.payload.status === "needs_input") {
          const input = await workflowStep.waitForEvent<{ payload?: string }>(
            `workflow:${task.step.kind}:needs-input`,
            { type: "workflow-input", timeout: "365 days" },
          );
          if (!input?.payload)
            return {
              task,
              status: "failed",
              error: "Workflow step input was not provided",
            };
          continue;
        }
        if (terminal.payload.status !== "completed") {
          if (definition.id !== "direct" && attempt < 3) continue;
          return {
            task,
            status:
              terminal.payload.status === "cancelled" ? "cancelled" : "failed",
            error: terminal.payload.error,
          };
        }
        if (
          typeof terminal.payload.finalText === "string" &&
          terminal.payload.finalText.trim()
        ) {
          const completedAt = new Date().toISOString();
          const stepResult: StepResult = {
            text: terminal.payload.finalText,
            status: "completed",
            startedAt,
            completedAt,
            workerId: terminal.payload.workerId ?? null,
            workerTypeId: terminal.payload.workerTypeId ?? null,
            engineVersion: terminal.payload.engineVersion ?? null,
            profileDefinitionId: terminal.payload.profileDefinitionId ?? null,
            profileReleaseVersion:
              terminal.payload.profileReleaseVersion ?? null,
            providerToolVersion: terminal.payload.providerToolVersion ?? null,
            model: terminal.payload.model ?? null,
          };
          return { task, status: "completed", output: stepResult, stepResult };
        }
        if (!terminal.payload.resultArtifactId) {
          return {
            task,
            status: "failed",
            error: "Workflow Step completed without a final answer artifact",
          };
        }
        const stepResult = await this.readWorkflowStepResult(
          terminal.payload.resultArtifactId,
          startedAt,
        );
        if (!stepResult?.text.trim()) {
          return {
            task,
            status: "failed",
            error: "Workflow Step final answer text is unavailable",
          };
        }
        return {
          task,
          status: "completed",
          output: stepResult,
          stepResult,
        };
      } catch (error) {
        if (definition.id === "direct" || attempt >= 3)
          return {
            task,
            status: "failed",
            error: error instanceof Error ? error.message : String(error),
          };
      }
    }
    return {
      task,
      status: "failed",
      error: "Workflow step retry limit exceeded",
    };
  }

  private async readWorkflowStepResult(
    artifactId: string,
    fallbackStartedAt: string,
  ): Promise<StepResult | null> {
    const db = (this.env as ExecutionEnv).CONCLAVE_DB;
    if (!db) return null;
    const row = await db
      .prepare(
        `SELECT a.created_at AS artifact_created_at,
                wa.workspace_worker_id AS worker_id,
                wa.worker_id AS worker_type_id,
                wa.model AS model,
                wa.engine_version AS engine_version,
                wa.created_at AS assignment_started_at,
                wa.permission_snapshot_json AS permission_snapshot_json
         FROM artifacts a
         LEFT JOIN worker_assignments wa ON wa.id = a.assignment_id
         WHERE a.id = ?1`,
      )
      .bind(artifactId)
      .first<Record<string, unknown>>();
    if (!row) return null;
    const text = await this.readWorkflowArtifactText(artifactId);
    if (!text.trim()) return null;
    let permissionSnapshot: Record<string, unknown> = {};
    if (typeof row.permission_snapshot_json === "string") {
      try {
        const parsed: unknown = JSON.parse(row.permission_snapshot_json);
        if (
          typeof parsed === "object" &&
          parsed !== null &&
          !Array.isArray(parsed)
        ) {
          permissionSnapshot = parsed as Record<string, unknown>;
        }
      } catch {
        // Attribution remains nullable if the assignment snapshot is malformed.
      }
    }
    const completedAt =
      typeof row.artifact_created_at === "string"
        ? row.artifact_created_at
        : new Date().toISOString();
    return {
      text,
      status: "completed",
      startedAt:
        typeof row.assignment_started_at === "string"
          ? row.assignment_started_at
          : fallbackStartedAt,
      completedAt,
      workerId: typeof row.worker_id === "string" ? row.worker_id : null,
      workerTypeId:
        typeof row.worker_type_id === "string" ? row.worker_type_id : null,
      engineVersion:
        typeof permissionSnapshot.profileDefinitionId === "string" &&
        typeof row.engine_version === "string"
          ? row.engine_version
          : null,
      profileDefinitionId:
        typeof permissionSnapshot.profileDefinitionId === "string"
          ? permissionSnapshot.profileDefinitionId
          : null,
      profileReleaseVersion:
        Number.isSafeInteger(permissionSnapshot.profileReleaseVersion) &&
        Number(permissionSnapshot.profileReleaseVersion) > 0
          ? Number(permissionSnapshot.profileReleaseVersion)
          : null,
      providerToolVersion:
        typeof permissionSnapshot.providerToolVersion === "string"
          ? permissionSnapshot.providerToolVersion
          : null,
      model: typeof row.model === "string" ? row.model : null,
      artifacts: [artifactId],
    };
  }

  private async readWorkflowArtifactText(artifactId: string): Promise<string> {
    const maxBytes = 24_000;
    const env = this.env as Env & {
      readonly CONCLAVE_ARTIFACTS?: R2Bucket;
    };
    const artifact = await env.CONCLAVE_DB.prepare(
      "SELECT * FROM artifacts WHERE id = ?1",
    )
      .bind(artifactId)
      .first<Record<string, unknown>>();
    if (!artifact) return "";
    if (typeof artifact.inline_content === "string") {
      return artifact.inline_content.length <= maxBytes
        ? artifact.inline_content
        : `${artifact.inline_content.slice(0, maxBytes)}\n[Step result truncated by Conclave.]`;
    }
    if (typeof artifact.storage_key !== "string" || !env.CONCLAVE_ARTIFACTS) {
      return "";
    }
    const object = await env.CONCLAVE_ARTIFACTS.get(artifact.storage_key);
    if (!object) return "";
    const reader = object.body.getReader();
    const decoder = new TextDecoder();
    let content = "";
    let bytesRead = 0;
    let truncated = false;
    try {
      while (bytesRead < maxBytes) {
        const { done, value } = await reader.read();
        if (done) break;
        const remaining = maxBytes - bytesRead;
        const chunk = value.subarray(0, remaining);
        content += decoder.decode(chunk, { stream: true });
        bytesRead += chunk.byteLength;
        if (chunk.byteLength < value.byteLength) {
          truncated = true;
          break;
        }
      }
      if (object.size > bytesRead) truncated = true;
      content += decoder.decode();
      if (truncated) {
        await reader.cancel();
        content += "\n[Step result truncated by Conclave.]";
      }
      return content;
    } finally {
      reader.releaseLock();
    }
  }

  private async loadWorkRequestPromptInput(
    params: ConclaveWorkflowParams,
  ): Promise<Record<string, unknown>> {
    const callerInput = params.input ?? {};
    if (!params.workRequestId) return callerInput;
    const db = (this.env as ExecutionEnv).CONCLAVE_DB;
    if (!db) return callerInput;
    const row = await db
      .prepare(
        `SELECT wr.input_json AS inputJson, wr.snapshot_json AS snapshotJson
         FROM work_requests wr
         WHERE wr.id = ?1`,
      )
      .bind(params.workRequestId)
      .first<{
        inputJson: string;
        snapshotJson: string | null;
      }>();
    if (!row) return callerInput;
    const parseRecord = (value: string | null | undefined) => {
      if (!value) return {};
      try {
        const parsed: unknown = JSON.parse(value);
        return typeof parsed === "object" &&
          parsed !== null &&
          !Array.isArray(parsed)
          ? (parsed as Record<string, unknown>)
          : {};
      } catch {
        return {};
      }
    };
    const persistedInput = parseRecord(row.inputJson);
    const snapshot = parseRecord(row.snapshotJson);
    const resolvedBindings =
      typeof snapshot.resolvedBindings === "object" &&
      snapshot.resolvedBindings !== null &&
      !Array.isArray(snapshot.resolvedBindings)
        ? snapshot.resolvedBindings
        : {};
    const workstreamInstructions =
      typeof snapshot.workstreamInstructions === "string"
        ? snapshot.workstreamInstructions
        : "";
    return {
      ...callerInput,
      ...persistedInput,
      originalRequest:
        typeof snapshot.originalRequest === "string"
          ? snapshot.originalRequest
          : "",
      projectInstructions:
        typeof snapshot.projectInstructions === "string"
          ? snapshot.projectInstructions
          : "",
      workstreamInstructions,
      stepInstructions:
        typeof snapshot.stepAdditionalInstructions === "object" &&
        snapshot.stepAdditionalInstructions !== null
          ? snapshot.stepAdditionalInstructions
          : {},
      workConfig: { bindings: resolvedBindings, workstreamInstructions },
      workRequestSnapshot: snapshot,
    };
  }

  private async loadWorkRequestSnapshot(
    workRequestId: string,
  ): Promise<WorkRequestSnapshot | null> {
    const db = (this.env as ExecutionEnv).CONCLAVE_DB;
    if (!db) return null;
    const row = await db
      .prepare(
        `SELECT snapshot_json AS snapshotJson,
                workflow_snapshot_json AS workflowSnapshotJson
         FROM work_requests WHERE id = ?1`,
      )
      .bind(workRequestId)
      .first<{ snapshotJson: string | null; workflowSnapshotJson: string }>();
    if (!row?.snapshotJson) return null;
    try {
      const snapshot = JSON.parse(row.snapshotJson) as WorkRequestSnapshot;
      const workflowSnapshot = JSON.parse(
        row.workflowSnapshotJson,
      ) as BuiltinWorkflowDefinition;
      if (snapshot.schemaVersion !== 1) return null;
      validateBuiltinWorkflowDefinition(workflowSnapshot);
      if (
        snapshot.workflowId !== workflowSnapshot.id ||
        snapshot.workflowVersion !== workflowSnapshot.version
      ) {
        return null;
      }
      return { ...snapshot, workflowSnapshot };
    } catch {
      return null;
    }
  }

  override async run(
    event: WorkflowEvent<ConclaveWorkflowParams>,
    step: WorkflowStep,
  ): Promise<ConclaveWorkflowCheckpoint> {
    let params = event.payload;
    if (params.workRequestId) {
      const snapshot = await this.loadWorkRequestSnapshot(params.workRequestId);
      if (snapshot) {
        params = { ...params, builtinWorkflow: snapshot.workflowSnapshot };
      }
    }
    if (params.builtinWorkflow) return this.runVersioned(params, step);
    const started = await step.do(
      "checkpoint:intake",
      stepConfig,
      async () => ({
        runId: params.runId,
        goalId: params.goalId,
        idempotencyKey: params.idempotencyKey,
        stage: "intake" as const,
        status: "active" as const,
      }),
    );

    let controlEvent: RunControlEvent | undefined;
    if (params.startPaused) {
      const event = await step.waitForEvent<RunControlEvent>(
        "wait for initial run control",
        { type: "run-control", timeout: "365 days" },
      );
      if (!isRunControlEvent(event.payload)) {
        throw new Error("Invalid run-control event payload");
      }
      controlEvent = event.payload;
    }
    if (controlEvent?.action === "cancel") {
      return step.do("checkpoint:cancelled", stepConfig, async () => ({
        ...started,
        stage: "cancelled" as const,
        status: "cancelled" as const,
        eventId: controlEvent.eventId,
        eventAction: controlEvent.action,
      }));
    }

    const research = await step.do(
      "checkpoint:research",
      stepConfig,
      async () => ({
        ...started,
        stage: "research" as const,
        status: "active" as const,
        ...(controlEvent
          ? { eventId: controlEvent.eventId, eventAction: controlEvent.action }
          : {}),
      }),
    );
    if (params.requireApproval) {
      const approvalEvent = await step.waitForEvent<ApprovalEvent>(
        "wait for external approval",
        { type: "run-approval", timeout: "365 days" },
      );
      if (!isApprovalEvent(approvalEvent.payload)) {
        throw new Error("Invalid run-approval event payload");
      }
      if (!approvalEvent.payload.approved) {
        return step.do(
          "checkpoint:cancelled-after-approval",
          stepConfig,
          async () => ({
            ...research,
            stage: "cancelled" as const,
            status: "cancelled" as const,
            eventId: approvalEvent.payload.eventId,
            eventAction: "approval_rejected",
          }),
        );
      }
    }

    const planning = await step.do(
      "checkpoint:planning",
      stepConfig,
      async () => ({
        ...research,
        stage: "planning" as const,
      }),
    );
    const implementation = await step.do(
      "checkpoint:implementation",
      stepConfig,
      async () => ({ ...planning, stage: "implementation" as const }),
    );

    const execution = await step.do("forge:execute", stepConfig, async () => {
      const service = (this.env as ExecutionEnv).CONCLAVE_FORGE_EXECUTION;
      if (!service) {
        throw new Error(
          "Forge execution service is not configured; refusing to complete a checkpoint-only run",
        );
      }
      const response = await service.fetch(
        "https://conclave.internal/execute",
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(params),
        },
      );
      if (!response.ok) {
        throw new Error(
          `Forge execution failed with status ${response.status}`,
        );
      }
      const body = (await response.json()) as { executionId?: unknown };
      if (typeof body.executionId !== "string") {
        throw new Error("Forge execution returned no executionId");
      }
      return {
        ...implementation,
        executionId: body.executionId,
        executionStatus: "started" as const,
      };
    });
    let forgeTerminal: ForgeTerminalEvent;
    let reconciliationAttempt = 0;
    while (true) {
      let terminalEvent: { payload: ForgeTerminalEvent };
      try {
        terminalEvent = await step.waitForEvent<ForgeTerminalEvent>(
          "wait for Forge terminal result",
          { type: "forge-terminal", timeout: "5 minutes" },
        );
      } catch {
        const status = await step.do(
          `forge:reconcile:${reconciliationAttempt}`,
          stepConfig,
          async () => {
            const service = (this.env as ExecutionEnv).CONCLAVE_FORGE_EXECUTION;
            if (!service) {
              throw new Error("Forge execution service is not configured");
            }
            const response = await service.fetch(
              `https://conclave.internal/status/${execution.executionId}`,
            );
            if (!response.ok) {
              throw new Error(
                `Forge status reconciliation failed with status ${response.status}`,
              );
            }
            const body: unknown = await response.json();
            if (!isForgeExecutionStatus(body)) {
              throw new Error(
                "Forge status reconciliation returned invalid data",
              );
            }
            return body;
          },
        );
        reconciliationAttempt += 1;
        if (status.status === "started") {
          await step.sleep(
            `forge:reconcile:wait:${reconciliationAttempt}`,
            "30 seconds",
          );
          continue;
        }
        terminalEvent = {
          payload: {
            eventId: `reconciled-${execution.executionId}-${reconciliationAttempt}`,
            runId: status.runId,
            executionId: status.executionId,
            status: status.status,
            ...(status.resultArtifactId
              ? { resultArtifactId: status.resultArtifactId }
              : {}),
            ...(status.error ? { error: status.error } : {}),
          },
        };
      }
      if (!isForgeTerminalEvent(terminalEvent.payload)) {
        throw new Error("Invalid Forge terminal event payload");
      }
      if (
        terminalEvent.payload.runId !== params.runId ||
        terminalEvent.payload.executionId !== execution.executionId
      ) {
        throw new Error("Forge terminal event does not match this run");
      }
      forgeTerminal = await step.do(
        `forge:terminal:${terminalEvent.payload.eventId}`,
        stepConfig,
        async () => terminalEvent.payload,
      );
      if (forgeTerminal.status !== "needs_input") break;
    }

    if (forgeTerminal.status !== "completed") {
      return step.do("checkpoint:forge-terminal", stepConfig, async () => {
        const status =
          forgeTerminal.status === "failed"
            ? ("failed" as const)
            : ("cancelled" as const);
        await this.persistTerminalRun(params.runId, status);
        return {
          ...execution,
          stage: status,
          status,
          executionStatus: forgeTerminal.status,
          ...(forgeTerminal.error
            ? { failureReason: forgeTerminal.error }
            : {}),
          ...(forgeTerminal.resultArtifactId
            ? { resultArtifactId: forgeTerminal.resultArtifactId }
            : {}),
        };
      });
    }

    let machineEvidence: MachineEvidenceEvent | undefined;
    if (params.requireCiEvidence !== false) {
      const ciEvent = await step.waitForEvent<MachineEvidenceEvent>(
        "wait for machine CI evidence",
        { type: "ci-evidence", timeout: "365 days" },
      );
      try {
        machineEvidence = parseMachineCheckEvidence(ciEvent.payload);
      } catch (error) {
        throw new Error(
          `Invalid CI evidence: ${error instanceof Error ? error.message : "unknown"}`,
        );
      }
      validateMachineEvidence(machineEvidence, params);
      if (machineEvidence.conclusion !== "success") {
        throw new Error(
          `Machine checks concluded ${machineEvidence.conclusion}`,
        );
      }
      const evidenceCheckpoint = await step.do(
        "checkpoint:machine-evidence",
        stepConfig,
        async () => ({
          ...implementation,
          stage: "implementation" as const,
          machineEvidence,
        }),
      );
      machineEvidence = evidenceCheckpoint.machineEvidence;
    }

    const verification = await step.do(
      "checkpoint:verification",
      stepConfig,
      async () => ({
        ...implementation,
        stage: "verification" as const,
        executionStatus: "completed" as const,
        ...(forgeTerminal.resultArtifactId
          ? { resultArtifactId: forgeTerminal.resultArtifactId }
          : {}),
        ...(machineEvidence ? { machineEvidence } : {}),
      }),
    );
    return step.do("checkpoint:completed", stepConfig, async () => {
      await this.persistTerminalRun(params.runId, "completed");
      return {
        ...verification,
        stage: "completed" as const,
        status: "completed" as const,
        executionStatus: "completed" as const,
      };
    });
  }
}
