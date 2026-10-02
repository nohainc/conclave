import {
  WorkflowEntrypoint,
  type WorkflowEvent,
  type WorkflowStep,
} from "cloudflare:workers";
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
import {
  dispatchTaskAssignment,
  type AssignmentDispatcherEnv,
} from "./assignment-dispatcher.js";
import type { WorkstreamBindingId } from "@conclave/core";

export interface ConclaveWorkflowParams {
  readonly runId: string;
  readonly goalId: string;
  readonly idempotencyKey: string;
  readonly organizationId?: string;
  /** Immutable definition for the Work v1 Cloud Workflow. */
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
  readonly stage: "workflow" | "completed" | "cancelled" | "failed";
  readonly status: "active" | "waiting" | "completed" | "cancelled" | "failed";
  readonly failureReason?: string;
  readonly workflowStepId?: string;
}

type ExecutionEnv = Env & {
  readonly CONCLAVE_WORKSTREAM_COORDINATOR?: DurableObjectNamespace;
};

interface AssignmentRow {
  status: string;
  outputJson: string | null;
  errorJson: string | null;
  workerId: string | null;
  workerTypeId: string | null;
  engineVersion: string | null;
  model: string | null;
  permissionSnapshotJson: string | null;
  assignmentId: string;
  startedAt: string;
}

function workStepSessionKey(params: {
  readonly workBindingId?: WorkstreamBindingId;
  readonly workstreamId: string;
  readonly workRequestId: string;
  readonly stepKind: string;
  readonly retryStepKind?: unknown;
  readonly retrySessionStrategy?: unknown;
  readonly retryNumber?: unknown;
}): string {
  const baseSessionKey =
    params.workBindingId === "direct"
      ? `workstream:${params.workstreamId}:direct:work-conversation`
      : `work-request:${params.workRequestId}:${params.stepKind}`;
  return params.retryStepKind === params.stepKind &&
    params.retrySessionStrategy === "fresh"
    ? `${baseSessionKey}:retry-fresh-${Number(params.retryNumber) || 1}`
    : baseSessionKey;
}

function parseJsonRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== "string") return {};
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
}

const stepConfig = {
  retries: {
    limit: 3,
    delay: "5 seconds" as const,
    backoff: "exponential" as const,
  },
  timeout: "5 minutes" as const,
} as const;

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
    const db = (this.env as ExecutionEnv).CONCLAVE_DB;
    if (!db || !params.workRequestId) {
      return {
        task,
        status: "failed",
        error: "Work Request execution context is unavailable",
      };
    }
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
        const assignment = await workflowStep.do(
          `workflow:${task.step.kind}:dispatch:${attempt}`,
          {
            ...stepConfig,
            timeout: "1 minute",
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
            if (!prompt.trim()) throw new Error("Work Step prompt is empty");
            const context = await db
              .prepare(
                `SELECT wr.workstream_id AS workstreamId,
                      wr.requested_by_user_id AS requesterUserId,
                      wr.status AS workRequestStatus,
                      wr.cancel_requested_at AS cancelRequestedAt,
                      ws.project_id AS projectId
                 FROM work_requests wr JOIN workstreams ws ON ws.id = wr.workstream_id
                WHERE wr.id = ?1`,
              )
              .bind(params.workRequestId)
              .first<{
                workstreamId: string;
                requesterUserId: string;
                workRequestStatus: string;
                cancelRequestedAt: string | null;
                projectId: string;
              }>();
            if (!context) throw new Error("Work Request was not found");
            if (
              context.workRequestStatus === "cancelled" ||
              context.cancelRequestedAt
            ) {
              return { status: "cancelled", assignmentId: "", startedAt };
            }
            const bindingId = workBindingId as WorkstreamBindingId;
            const {
              workConfig: _workConfig,
              workRequestSnapshot: _snapshot,
              ...workerInput
            } = promptInput;
            const dispatched = await dispatchTaskAssignment(
              this.env as unknown as AssignmentDispatcherEnv,
              {
                workspaceId: params.organizationId ?? "",
                runId: params.runId,
                taskId: task.id,
                explicitWorkerId:
                  typeof stepBinding.workerId === "string"
                    ? stepBinding.workerId
                    : undefined,
                explicitAttemptNumber: attempt,
                task: {
                  id: task.id,
                  role: task.step.kind,
                  objective: prompt,
                  capabilities: task.step.requiredCapabilities,
                  input: {
                    ...workerInput,
                    prompt,
                    effectiveWorkerPrompt: prompt,
                  },
                  timeoutMs: task.step.timeoutMs,
                  sessionPolicy: "durable_session",
                  sessionKey: workStepSessionKey({
                    workBindingId: bindingId,
                    workstreamId: context.workstreamId,
                    workRequestId: params.workRequestId!,
                    stepKind: task.step.kind,
                    retryStepKind: params.retryStepKind,
                    retrySessionStrategy: params.retrySessionStrategy,
                    retryNumber: params.retryNumber,
                  }),
                  projectId: context.projectId,
                  requestedByUserId: context.requesterUserId,
                  workstreamId: context.workstreamId,
                  workRequestId: params.workRequestId,
                  workBindingId: bindingId,
                  executionClass: task.step.executionMode,
                  readOnly: task.step.readWritePolicy === "read_only",
                  model:
                    typeof stepBinding.model === "string"
                      ? stepBinding.model
                      : undefined,
                },
              },
            );
            if (dispatched.status === "cancelled") {
              return {
                status: "cancelled",
                assignmentId: dispatched.assignmentId,
                startedAt,
              };
            }
            if (!dispatched.accepted || !dispatched.assignmentId) {
              throw new Error(
                dispatched.error ?? `${task.step.kind} Worker dispatch failed`,
              );
            }
            return {
              status: "dispatched",
              assignmentId: dispatched.assignmentId,
              startedAt,
            };
          },
        );
        if (assignment.status === "cancelled") {
          return {
            task,
            status: "cancelled",
            error: "Work assignment was cancelled",
          };
        }
        let terminal: AssignmentRow | null = null;
        const pollCount = Math.max(1, Math.ceil(task.step.timeoutMs / 2_000));
        for (let poll = 0; poll < pollCount; poll += 1) {
          terminal = await workflowStep.do(
            `workflow:${task.step.kind}:assignment-status:${attempt}:${poll}`,
            { ...stepConfig, timeout: "30 seconds" },
            async () =>
              db
                .prepare(
                  `SELECT wa.id AS assignmentId, wa.status, wa.output_json AS outputJson,
                      wa.error_json AS errorJson, wa.workspace_worker_id AS workerId,
                      wa.worker_type_id AS workerTypeId, wa.engine_version AS engineVersion,
                      wa.model, wa.permission_snapshot_json AS permissionSnapshotJson,
                      wa.created_at AS startedAt
                 FROM worker_assignments wa WHERE wa.id = ?1`,
                )
                .bind(assignment.assignmentId)
                .first<AssignmentRow>(),
          );
          if (
            terminal &&
            ["completed", "failed", "cancelled"].includes(terminal.status)
          )
            break;
          await workflowStep.sleep(
            `workflow:${task.step.kind}:assignment-wait:${attempt}:${poll}`,
            "2 seconds",
          );
        }
        if (terminal?.status === "cancelled") {
          return {
            task,
            status: "cancelled",
            error: "Work assignment was cancelled",
          };
        }
        if (terminal?.status === "failed") {
          const errorRecord = parseJsonRecord(terminal.errorJson);
          const errorValue = parseJsonRecord(errorRecord.error);
          throw new Error(
            typeof errorValue.message === "string"
              ? errorValue.message
              : "Worker assignment failed",
          );
        }
        if (terminal?.status !== "completed" || !terminal.outputJson) {
          throw new Error("Work Step assignment timed out");
        }
        const rawOutput = parseJsonRecord(terminal.outputJson);
        const nested =
          typeof rawOutput.output === "object" && rawOutput.output !== null
            ? (rawOutput.output as Record<string, unknown>)
            : rawOutput;
        const finalText =
          typeof nested.text === "string"
            ? nested.text
            : typeof nested.finalAnswer === "string"
              ? nested.finalAnswer
              : typeof nested.summary === "string"
                ? nested.summary
                : null;
        if (!finalText?.trim())
          throw new Error("Work Step completed without final answer text");
        const evidence = parseJsonRecord(terminal.permissionSnapshotJson);
        const completedAt = new Date().toISOString();
        const stepResult: StepResult = {
          text: finalText.slice(0, 96_000),
          status: "completed",
          startedAt: terminal.startedAt || startedAt,
          completedAt,
          workerId: terminal.workerId,
          workerTypeId: terminal.workerTypeId,
          engineVersion:
            typeof evidence.profileDefinitionId === "string"
              ? terminal.engineVersion
              : null,
          profileDefinitionId:
            typeof evidence.profileDefinitionId === "string"
              ? evidence.profileDefinitionId
              : null,
          profileReleaseVersion:
            Number.isSafeInteger(evidence.profileReleaseVersion) &&
            Number(evidence.profileReleaseVersion) > 0
              ? Number(evidence.profileReleaseVersion)
              : null,
          providerToolVersion:
            typeof evidence.providerToolVersion === "string"
              ? evidence.providerToolVersion
              : null,
          model: terminal.model,
        };
        return { task, status: "completed", output: stepResult, stepResult };
      } catch (error) {
        if (
          error instanceof Error &&
          error.name === "WorkAssignmentCancelledError"
        ) {
          return { task, status: "cancelled", error: error.message };
        }
        if (definition.id === "direct" || attempt >= 3) {
          return {
            task,
            status: "failed",
            error: error instanceof Error ? error.message : String(error),
          };
        }
      }
    }
    return {
      task,
      status: "failed",
      error: "Workflow step retry limit exceeded",
    };
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
      if (snapshot)
        params = { ...params, builtinWorkflow: snapshot.workflowSnapshot };
    }
    if (!params.builtinWorkflow) {
      throw new Error("A versioned built-in Work v1 Workflow is required");
    }
    return this.runVersioned(params, step);
  }
}
