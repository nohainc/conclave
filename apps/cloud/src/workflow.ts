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
  validateWorkflowOutput,
  validateWorkflowVersion,
  type PlannedWorkflowTask,
  type WorkflowVersion,
} from "@conclave/core";

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
  /** Immutable v6 product workflow snapshot. When present, the data-driven runner is used. */
  readonly workflowVersion?: WorkflowVersion;
  readonly workRequestId?: string;
  readonly input?: Record<string, unknown>;
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
         (id, work_request_id, workflow_version_id, workflow_step_id, execution_class,
          role, required_capabilities_json, approval, timeout_ms, output_contract_json,
          status, attempt, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'queued', 0, ?11, ?11)
         ON CONFLICT(work_request_id, workflow_step_id) DO NOTHING`,
        )
        .bind(
          task.id,
          task.workRequestId,
          task.workflowVersionId,
          task.step.id,
          task.step.executionClass,
          task.step.role,
          JSON.stringify(task.step.requiredCapabilities),
          task.step.approval,
          task.step.timeoutMs,
          JSON.stringify(task.step.outputContract),
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

  private async persistWorkflowTaskState(
    task: PlannedWorkflowTask,
    output?: unknown,
    error?: string,
  ): Promise<void> {
    const db = (this.env as ExecutionEnv).CONCLAVE_DB;
    if (!db) return;
    await db
      .prepare(
        `UPDATE workflow_tasks SET status = ?1, attempt = ?2, output_json = ?3,
       error = ?4, updated_at = ?5 WHERE id = ?6`,
      )
      .bind(
        task.status,
        task.attempt,
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
    const version = params.workflowVersion!;
    validateWorkflowVersion(version);
    const workRequestId = params.workRequestId ?? `run-${params.runId}`;
    let tasks = [...planWorkflowTasks(version, workRequestId)];
    await this.persistWorkflowTasks(params, tasks);
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
        return {
          ...started,
          stage: failed?.status === "cancelled" ? "cancelled" : "failed",
          status: failed?.status === "cancelled" ? "cancelled" : "failed",
          workflowStepId: failed?.step.id,
          failureReason: failed
            ? `Workflow step ${failed.step.name} ${failed.status}`
            : "Workflow has no runnable steps",
        };
      }
      // Stateful Workstream steps are never concurrent. Independent stateless
      // steps can share one durable Workflow batch.
      const batch = ready.some(
        (task) => task.step.executionClass === "stateful_workstream",
      )
        ? [
            ready.find(
              (task) => task.step.executionClass === "stateful_workstream",
            )!,
          ]
        : ready;
      const results = await Promise.all(
        batch.map((task) => this.runWorkflowTask(params, task, step)),
      );
      for (const result of results) {
        tasks = [
          ...markWorkflowTaskResult(tasks, result.task.id, result.status),
        ];
        await this.persistWorkflowTaskState(
          result.task,
          result.output,
          result.error,
        );
        if (result.status === "failed" || result.status === "cancelled") {
          const failed = tasks.find(
            (candidate) => candidate.id === result.task.id,
          )!;
          return {
            ...started,
            stage: result.status,
            status: result.status,
            workflowStepId: failed.step.id,
            failureReason:
              result.error ??
              `Workflow step ${failed.step.name} ${result.status}`,
          };
        }
      }
    }
    await this.persistTerminalRun(params.runId, "completed");
    return { ...started, stage: "completed", status: "completed" };
  }

  private async runWorkflowTask(
    params: ConclaveWorkflowParams,
    task: PlannedWorkflowTask,
    workflowStep: WorkflowStep,
  ): Promise<{
    task: PlannedWorkflowTask;
    status: "completed" | "failed" | "cancelled";
    output?: unknown;
    error?: string;
  }> {
    if (task.step.approval !== "none") {
      const approval = await workflowStep.waitForEvent<ApprovalEvent>(
        `workflow:approval:${task.step.id}`,
        { type: "run-approval", timeout: "365 days" },
      );
      if (!isApprovalEvent(approval.payload) || !approval.payload.approved) {
        return {
          task,
          status: "cancelled",
          error: "Workflow approval was rejected",
        };
      }
    }
    const service = (this.env as ExecutionEnv).CONCLAVE_FORGE_EXECUTION;
    if (!service)
      return {
        task,
        status: "failed",
        error: "Forge execution service is not configured",
      };
    let attempt = 0;
    while (attempt < 3) {
      attempt += 1;
      try {
        const execution = await workflowStep.do(
          `workflow:${task.step.id}:execute:${attempt}`,
          {
            ...stepConfig,
            timeout:
              `${Math.max(1, Math.ceil(task.step.timeoutMs / 1000))} seconds` as `${number} seconds`,
          },
          async () => {
            const response = await service.fetch(
              "https://conclave.internal/execute",
              {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({
                  ...params,
                  workflowStep: task.step,
                  input: params.input ?? {},
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
          `workflow:${task.step.id}:terminal:${attempt}`,
          { type: "forge-terminal", timeout: "5 minutes" },
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
            `workflow:${task.step.id}:needs-input`,
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
          if (attempt < 3) continue;
          return {
            task,
            status:
              terminal.payload.status === "cancelled" ? "cancelled" : "failed",
            error: terminal.payload.error,
          };
        }
        const output = {
          summary: task.step.name,
          resultArtifactId: terminal.payload.resultArtifactId,
        };
        validateWorkflowOutput(output, task.step.outputContract);
        return { task, status: "completed", output };
      } catch (error) {
        if (attempt >= 3)
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

  override async run(
    event: WorkflowEvent<ConclaveWorkflowParams>,
    step: WorkflowStep,
  ): Promise<ConclaveWorkflowCheckpoint> {
    const params = event.payload;
    if (params.workflowVersion) return this.runVersioned(params, step);
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
