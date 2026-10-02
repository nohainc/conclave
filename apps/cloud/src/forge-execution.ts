import type { WorkstreamBindingId } from "@conclave/core";
import type { D1DatabaseLike } from "@conclave/persistence";
import {
  dispatchTaskAssignment,
  type AssignmentDispatcherEnv,
  type DispatchAssignmentResult,
} from "./assignment-dispatcher.js";

interface ForgeExecutionEnv {
  readonly CONCLAVE_DB: D1DatabaseLike;
  readonly CONCLAVE_API_BASE_URL?: string;
  readonly CONCLAVE_API?: Fetcher;
  readonly CONCLAVE_FORGE_CALLBACK_TOKEN?: string;
  readonly CONCLAVE_WORKSPACE_GATEWAY?: DurableObjectNamespace;
}

interface ForgeExecutionRecord {
  readonly executionId: string;
  readonly runId: string;
  readonly status: "started" | "completed" | "failed" | "cancelled" | "needs_input";
  readonly resultArtifactId?: string;
  readonly error?: string;
  readonly updatedAt: string;
}

/** Stable provider-session partition for one logical Work v1 binding. */
export function workStepSessionKey(params: {
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

function forgeExecutionRecord(
  row: Record<string, unknown>,
): ForgeExecutionRecord {
  return {
    executionId: String(row.execution_id),
    runId: String(row.run_id),
    status: String(row.status) as ForgeExecutionRecord["status"],
    ...(row.result_artifact_id
      ? { resultArtifactId: String(row.result_artifact_id) }
      : {}),
    ...(row.error ? { error: String(row.error) } : {}),
    updatedAt: String(row.updated_at),
  };
}

function parseJsonRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== "string") return {};
  try {
    const parsed: unknown = JSON.parse(value);
    return typeof parsed === "object" && parsed !== null
      ? (parsed as Record<string, unknown>)
      : {};
  } catch {
    return {};
  }
}

async function executeBoundWorkStepAssignment(
  env: ForgeExecutionEnv,
  params: Record<string, unknown>,
): Promise<{
  text: string;
  workerId: string | null;
  workerTypeId: string | null;
  engineVersion: string | null;
  profileDefinitionId: string | null;
  profileReleaseVersion: number | null;
  providerToolVersion: string | null;
  model: string | null;
}> {
  const workRequestId = String(params.workRequestId ?? "");
  const workflowStep =
    params.workflowStep && typeof params.workflowStep === "object"
      ? (params.workflowStep as Record<string, unknown>)
      : {};
  const stepKind =
    typeof workflowStep.kind === "string" ? workflowStep.kind : "";
  const executionMode =
    workflowStep.executionMode === "stateful_workstream"
      ? "stateful_workstream"
      : workflowStep.executionMode === "stateless_read"
        ? "stateless_read"
        : null;
  const readOnly = workflowStep.readWritePolicy === "read_only";
  const requiredCapabilities = Array.isArray(workflowStep.requiredCapabilities)
    ? workflowStep.requiredCapabilities.filter(
        (capability): capability is string => typeof capability === "string",
      )
    : [];
  if (
    !["research", "plan", "implement", "test", "verify"].includes(stepKind) ||
    !executionMode ||
    !["read_only", "write_workstream"].includes(
      String(workflowStep.readWritePolicy),
    ) ||
    requiredCapabilities.length === 0
  ) {
    throw new Error("Work Step execution contract is invalid");
  }
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT wr.workstream_id AS workstreamId, wr.requested_by_user_id AS requesterUserId,
            wr.status AS workRequestStatus, wr.cancel_requested_at AS cancelRequestedAt,
            ws.project_id AS projectId
       FROM work_requests wr JOIN workstreams ws ON ws.id = wr.workstream_id
      WHERE wr.id = ?1`,
  )
    .bind(workRequestId)
    .first<{
      workstreamId: string;
      requesterUserId: string;
      workRequestStatus: string;
      cancelRequestedAt: string | null;
      projectId: string;
    }>();
  if (!row || !workRequestId) throw new Error("Work Request was not found");
  if (row.workRequestStatus === "cancelled" || row.cancelRequestedAt)
    throw new WorkAssignmentCancelledError();
  const prompt =
    typeof params.effectiveWorkerPrompt === "string"
      ? params.effectiveWorkerPrompt
      : "";
  if (!prompt.trim()) throw new Error("Work Step prompt is empty");
  const taskId = String(params.taskId ?? `${stepKind}-${workRequestId}`);
  // Direct keeps one conversation for this Workstream's Direct binding.
  // Multi-step Workflows isolate a durable retry session by Work Request and
  // Step, so Verify never resumes Implement's provider conversation.
  const sessionKey = workStepSessionKey({
    workBindingId: params.workBindingId === "direct" ? "direct" : undefined,
    workstreamId: row.workstreamId,
    workRequestId,
    stepKind,
    retryStepKind: params.retryStepKind,
    retrySessionStrategy: params.retrySessionStrategy,
    retryNumber: params.retryNumber,
  });
  const dispatched = await dispatchTaskAssignment(
    env as unknown as AssignmentDispatcherEnv,
    {
      workspaceId: String(params.organizationId ?? ""),
      runId: String(params.runId ?? ""),
      taskId,
      task: {
        id: taskId,
        role: stepKind,
        objective: prompt,
        capabilities: requiredCapabilities,
        input: { prompt },
        timeoutMs:
          typeof workflowStep.timeoutMs === "number"
            ? workflowStep.timeoutMs
            : 15 * 60_000,
        sessionPolicy: "durable_session",
        sessionKey,
        projectId: row.projectId,
        requestedByUserId: row.requesterUserId,
        workstreamId: row.workstreamId,
        workRequestId,
        workBindingId:
          params.workBindingId === "direct"
            ? "direct"
            : (stepKind as WorkstreamBindingId),
        executionClass: executionMode,
        readOnly,
      },
    },
  );
  if (dispatched.status === "cancelled")
    throw new WorkAssignmentCancelledError();
  if (!dispatched.accepted)
    throw new Error(dispatched.error ?? `${stepKind} Worker dispatch failed`);
  const timeoutMs =
    typeof workflowStep.timeoutMs === "number"
      ? workflowStep.timeoutMs
      : 15 * 60_000;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const assignment = await env.CONCLAVE_DB.prepare(
      `SELECT wa.status, wa.output_json, wa.error_json,
              wa.workspace_worker_id AS workerId, wa.worker_id AS workerTypeId,
              wa.engine_version AS engineVersion, wa.model AS model,
              wa.permission_snapshot_json AS permissionSnapshotJson
       FROM worker_assignments wa
       WHERE wa.id = ?1`,
    )
      .bind(dispatched.assignmentId)
      .first<{
        status: string;
        output_json: string | null;
        error_json: string | null;
        workerId: string | null;
        workerTypeId: string | null;
        engineVersion: string | null;
        model: string | null;
        permissionSnapshotJson: string | null;
      }>();
    if (assignment?.status === "completed" && assignment.output_json) {
      const output = JSON.parse(assignment.output_json) as Record<
        string,
        unknown
      >;
      const nested =
        typeof output.output === "object" && output.output !== null
          ? (output.output as Record<string, unknown>)
          : output;
      const text =
        typeof nested.text === "string"
          ? nested.text
          : typeof nested.finalAnswer === "string"
            ? nested.finalAnswer
            : typeof nested.summary === "string"
              ? nested.summary
              : null;
      if (text?.trim()) {
        const evidence = parseJsonRecord(assignment.permissionSnapshotJson);
        const profileReleaseVersion = evidence.profileReleaseVersion;
        return {
          text: text.slice(0, 96_000),
          workerId: assignment.workerId,
          workerTypeId: assignment.workerTypeId,
          engineVersion:
            typeof evidence.profileDefinitionId === "string"
              ? assignment.engineVersion
              : null,
          profileDefinitionId:
            typeof evidence.profileDefinitionId === "string"
              ? evidence.profileDefinitionId
              : null,
          profileReleaseVersion:
            Number.isSafeInteger(profileReleaseVersion) &&
            Number(profileReleaseVersion) > 0
              ? Number(profileReleaseVersion)
              : null,
          providerToolVersion:
            typeof evidence.providerToolVersion === "string"
              ? evidence.providerToolVersion
              : null,
          model: assignment.model,
        };
      }
      throw new Error("Work Step completed without final answer text");
    }
    if (assignment?.status === "cancelled") {
      throw new WorkAssignmentCancelledError();
    }
    if (assignment?.status === "failed") {
      throw new Error(assignment.error_json ?? "Worker assignment failed");
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("Work Step assignment timed out");
}

class WorkAssignmentCancelledError extends Error {
  constructor() {
    super("Work assignment was cancelled");
    this.name = "WorkAssignmentCancelledError";
  }
}

export class ConclaveForgeExecutionService {
  constructor(private readonly env: ForgeExecutionEnv) {}

  async fetch(request: Request, ctx: ExecutionContext): Promise<Response> {
    const pathname = new URL(request.url).pathname;
    const statusMatch = pathname.match(/^\/status\/([^/]+)$/);
    if (request.method === "GET" && statusMatch?.[1]) {
      const row = await this.env.CONCLAVE_DB.prepare(
        "SELECT external_id AS execution_id, run_id, status, result_artifact_id, error, updated_at FROM run_external_executions WHERE external_id = ?1",
      )
        .bind(statusMatch[1])
        .first<Record<string, unknown>>();
      if (!row)
        return Response.json({ error: "execution_not_found" }, { status: 404 });
      return Response.json(forgeExecutionRecord(row));
    }
    if (request.method !== "POST" || pathname !== "/execute") {
      return Response.json({ error: "not_found" }, { status: 404 });
    }
    const params = (await request.json()) as Record<string, unknown>;
    if (typeof params.runId !== "string" || params.runId.length === 0) {
      return Response.json({ error: "run_id_required" }, { status: 400 });
    }
    const executionKind = [
      String(params.workBindingId ?? ""),
      String(params.taskId ?? ""),
      String(params.retryNumber ?? "1"),
    ].join(":");
    const responseForExecution = (row: Record<string, unknown>): Response => {
      const persisted = forgeExecutionRecord(row);
      return Response.json(
        {
          executionId: persisted.executionId,
          runId: persisted.runId,
          status: persisted.status,
          ...(persisted.resultArtifactId
            ? { resultArtifactId: persisted.resultArtifactId }
            : {}),
          ...(persisted.error ? { error: persisted.error } : {}),
        },
        { status: persisted.status === "started" ? 202 : 200 },
      );
    };
    const existing = await this.env.CONCLAVE_DB.prepare(
      `SELECT external_id AS execution_id, run_id, status, result_artifact_id, error, updated_at
       FROM run_external_executions WHERE run_id = ?1 AND execution_kind = ?2`,
    )
      .bind(params.runId, executionKind)
      .first<Record<string, unknown>>();
    if (existing) {
      return responseForExecution(existing);
    }
    if (!params.workRequestId || !params.workBindingId) {
      return Response.json({ error: "work_request_required" }, { status: 400 });
    }
    const executionId = crypto.randomUUID();
    const runId = params.runId;
    const now = new Date().toISOString();
    const record: ForgeExecutionRecord = {
      executionId,
      runId,
      status: "started",
      updatedAt: now,
    };
    await this.env.CONCLAVE_DB.prepare(
      `INSERT INTO run_external_executions
       (id, run_id, execution_kind, external_id, status, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
       ON CONFLICT(run_id, execution_kind) DO NOTHING`,
    )
      .bind(
        executionId,
        runId,
        executionKind,
        executionId,
        record.status,
        now,
      )
      .run();
    const persisted = await this.env.CONCLAVE_DB.prepare(
      `SELECT external_id AS execution_id, run_id, status, result_artifact_id, error, updated_at
       FROM run_external_executions WHERE run_id = ?1 AND execution_kind = ?2`,
    )
      .bind(runId, executionKind)
      .first<Record<string, unknown>>();
    if (!persisted) {
      return Response.json(
        { error: "work_execution_persistence_failed" },
        { status: 500 },
      );
    }
    if (String(persisted.execution_id) !== executionId) {
      return responseForExecution(persisted);
    }
    ctx.waitUntil(this.runAndNotify(params, executionId));
    return Response.json({ executionId }, { status: 202 });
  }

  private async updateExecution(
    executionId: string,
    patch: Omit<Partial<ForgeExecutionRecord>, "executionId" | "runId">,
  ): Promise<void> {
    const row = await this.env.CONCLAVE_DB.prepare(
      "SELECT external_id AS execution_id, run_id, status, result_artifact_id, error, updated_at FROM run_external_executions WHERE external_id = ?1",
    )
      .bind(executionId)
      .first<Record<string, unknown>>();
    if (!row) return;
    const existing = forgeExecutionRecord(row);
    const updated: ForgeExecutionRecord = {
      ...existing,
      ...patch,
      executionId,
      updatedAt: new Date().toISOString(),
    };
    await this.env.CONCLAVE_DB.prepare(
      `UPDATE run_external_executions
       SET status = ?1, result_artifact_id = ?2, error = ?3, updated_at = ?4
       WHERE external_id = ?5`,
    )
      .bind(
        updated.status,
        updated.resultArtifactId ?? null,
        updated.error ?? null,
        updated.updatedAt,
        executionId,
      )
      .run();
  }

  private async runAndNotify(
    params: Record<string, unknown>,
    executionId: string,
  ): Promise<void> {
    const runId = String(params.runId ?? "");
    let resultArtifactId: string | undefined;
    let workStepResult:
      Awaited<ReturnType<typeof executeBoundWorkStepAssignment>> | undefined;
    try {
      if (!this.env.CONCLAVE_WORKSPACE_GATEWAY) {
        throw new Error("Workspace Gateway is not configured");
      }
      if (
        !["direct", "research", "plan", "implement", "test", "verify"].includes(
          String(params.workBindingId),
        ) ||
        typeof params.workRequestId !== "string"
      ) {
        throw new Error("Only Work v1 assignment execution is supported");
      }
      workStepResult = await executeBoundWorkStepAssignment(this.env, params);
    } catch (error) {
      const cancelled = error instanceof WorkAssignmentCancelledError;
      const message = cancelled
        ? "Work assignment was cancelled"
        : error instanceof Error
          ? error.message
          : "Forge execution failed";
      await this.updateExecution(executionId, {
        status: cancelled ? "cancelled" : "failed",
        error: message,
      });
      await this.notifyBestEffort(runId, {
        eventId: crypto.randomUUID(),
        runId,
        executionId,
        status: cancelled ? "cancelled" : "failed",
        error: message,
      });
      return;
    }

    // Persist the terminal Forge result before notifying the Workflow. A
    // callback outage must not rewrite a real completion as a Forge failure.
    await this.updateExecution(executionId, {
      status: "completed",
      resultArtifactId,
    });
    await this.notifyBestEffort(runId, {
      eventId: crypto.randomUUID(),
      runId,
      executionId,
      status: "completed",
      ...(resultArtifactId ? { resultArtifactId } : {}),
      ...(workStepResult
        ? {
            finalText: workStepResult.text,
            workerId: workStepResult.workerId,
            workerTypeId: workStepResult.workerTypeId,
            engineVersion: workStepResult.engineVersion,
            profileDefinitionId: workStepResult.profileDefinitionId,
            profileReleaseVersion: workStepResult.profileReleaseVersion,
            providerToolVersion: workStepResult.providerToolVersion,
            model: workStepResult.model,
          }
        : {}),
    });
  }

  private async notifyBestEffort(
    runId: string,
    payload: Record<string, unknown>,
  ): Promise<void> {
    try {
      await this.notify(runId, payload);
    } catch {
      // The D1 execution record is authoritative and can be reconciled after
      // a callback outage or service restart.
    }
  }

  private async notify(
    runId: string,
    payload: Record<string, unknown>,
  ): Promise<void> {
    const callbackRequest = new Request(
      this.env.CONCLAVE_API
        ? `https://conclave.internal/api/runs/${encodeURIComponent(runId)}/forge-events`
        : `${this.env.CONCLAVE_API_BASE_URL!.replace(/\/$/, "")}/api/runs/${encodeURIComponent(runId)}/forge-events`,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          ...(this.env.CONCLAVE_FORGE_CALLBACK_TOKEN
            ? {
                authorization: `Bearer ${this.env.CONCLAVE_FORGE_CALLBACK_TOKEN}`,
              }
            : {}),
        },
        body: JSON.stringify(payload),
      },
    );
    const response = await (this.env.CONCLAVE_API
      ? this.env.CONCLAVE_API.fetch(callbackRequest)
      : fetch(callbackRequest));
    if (!response.ok)
      throw new Error(`Forge callback failed with ${response.status}`);
  }
}


export default {
  fetch(request: Request, env: ForgeExecutionEnv, ctx: ExecutionContext) {
    return new ConclaveForgeExecutionService(env).fetch(request, ctx);
  },
};
