import { loadConversationWorkflowRuns } from "./conversation-workflow-runs.js";
import {
  loadConversationTurns,
  withConversationTurn,
} from "./conversation-turns.js";
import {
  cancelTaskAssignment,
  type AssignmentDispatcherEnv,
} from "../assignment-dispatcher.js";
import {
  STEP_KINDS,
  BUILTIN_WORKFLOW_CATALOG,
  type BuiltinWorkflowDefinition,
  type StepKind,
} from "@conclave/core";
import {
  canonicalExecutionErrorCode,
  executionErrorMessage,
} from "@conclave/protocol";

import {
  HttpError,
  authorizeThreadAccess,
  json,
  parseJson,
  resolveWorkflowInstanceId,
  summarizeTestCounts,
  validateWorkflowWorkerEligibility,
} from "./handlers.js";
import type { SecurityEnv } from "./handlers.js";

import { createOrGetRun } from "./work-creation.js";

function historicalWorkflowName(
  snapshot: { readonly name?: unknown },
  workflowId: unknown,
  workflowVersion: unknown,
): string {
  return typeof snapshot.name === "string" && snapshot.name.trim()
    ? snapshot.name
    : (BUILTIN_WORKFLOW_CATALOG[
        `${String(workflowId)}:v${Number(workflowVersion)}`
      ]?.name ?? String(workflowId));
}

export async function handleRetryWorkRequest(
  request: Request,
  env: SecurityEnv,
  workRequestId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const parent = await env.CONCLAVE_DB.prepare(
    "SELECT thread_id AS threadId FROM work_requests WHERE id = ?1",
  )
    .bind(workRequestId)
    .first<{ threadId: string }>();
  if (!parent) throw new HttpError(404, "Work Request not found");
  const { context, spaceId } = await authorizeThreadAccess(
    request,
    env,
    parent.threadId,
    "execute",
    accessContext,
  );
  const membership = await env.CONCLAVE_DB.prepare(
    "SELECT role FROM space_memberships WHERE space_id = ?1 AND user_id = ?2",
  )
    .bind(spaceId, context.userId)
    .first<{ role: string }>();
  if (!membership || membership.role === "viewer")
    throw new HttpError(
      403,
      "Space membership with execute access is required",
    );
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT wr.thread_id AS threadId, wr.mode, wr.status,
            wr.workflow_id AS workflowId, wr.workflow_version AS workflowVersion,
            wr.workflow_snapshot_json AS workflowSnapshotJson,
            wr.snapshot_json AS snapshotJson, (SELECT text FROM conversation_history_entries h WHERE h.work_request_id = wr.id AND h.kind = 'user_message' LIMIT 1) AS canonicalUserText, wr.input_json AS inputJson,
            wr.primary_workspace_id AS primaryWorkspaceId,
            ws.space_id AS spaceId
       FROM work_requests wr JOIN threads ws ON ws.id = wr.thread_id
      WHERE wr.id = ?1`,
  )
    .bind(workRequestId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Work Request not found");
  if (row.status !== "failed")
    throw new HttpError(409, "Only a failed Work Request can be retried");

  const body = parseJson<Record<string, unknown>>(await request.text(), {});
  const stepKind = body.stepKind;
  if (
    typeof stepKind !== "string" ||
    !STEP_KINDS.includes(stepKind as StepKind)
  )
    throw new HttpError(400, "A valid failed Step is required");
  const workflow = parseJson<BuiltinWorkflowDefinition>(
    String(row.workflowSnapshotJson),
    {} as BuiltinWorkflowDefinition,
  );
  const step = workflow.steps?.find((candidate) => candidate.kind === stepKind);
  if (!step) throw new HttpError(400, "Step is not part of this Workflow");
  const failedTask = await env.CONCLAVE_DB.prepare(
    `SELECT wt.status, wt.error,
            (SELECT wa.error_json FROM worker_assignments wa
              WHERE wa.task_id = wt.id ORDER BY wa.created_at DESC, wa.id DESC LIMIT 1)
              AS assignmentErrorJson
       FROM workflow_tasks wt
      WHERE wt.work_request_id = ?1 AND wt.step_kind = ?2`,
  )
    .bind(workRequestId, stepKind)
    .first<{
      status: string;
      error: string | null;
      assignmentErrorJson: string | null;
    }>();
  if (failedTask?.status !== "failed")
    throw new HttpError(409, "Only a failed Step can be retried");

  const retrySessionStrategy = body.sessionStrategy;
  if (
    stepKind === "implement" &&
    retrySessionStrategy !== "resume" &&
    retrySessionStrategy !== "fresh"
  )
    throw new HttpError(
      400,
      "Choose whether the Implement retry resumes the previous session or starts fresh",
    );
  if (stepKind !== "implement" && retrySessionStrategy !== undefined)
    throw new HttpError(400, "Session strategy only applies to Implement");

  const snapshot = parseJson<Record<string, unknown>>(
    String(row.snapshotJson),
    {},
  );
  const bindings =
    typeof snapshot.resolvedBindings === "object" &&
    snapshot.resolvedBindings !== null
      ? (snapshot.resolvedBindings as Record<
          string,
          { workerId?: string; model?: string }
        >)
      : {};
  const attachmentInput = parseJson<Record<string, unknown>>(
    String(row.inputJson),
    {},
  );
  const eligibility = await validateWorkflowWorkerEligibility(
    env,
    String(row.spaceId),
    String(row.threadId),
    { ...workflow, steps: [step] },
    bindings,
    Array.isArray(attachmentInput.attachments)
      ? attachmentInput.attachments
      : [],
  );
  if (eligibility.issues.length > 0) {
    return json(
      { error: "work_request_ineligible", issues: eligibility.issues },
      { status: 422 },
    );
  }

  const latestRuns = await env.CONCLAVE_DB.prepare(
    "SELECT COUNT(*) AS count FROM runs WHERE work_request_id = ?1",
  )
    .bind(workRequestId)
    .first<{ count: number }>();
  const retryNumber = Math.max(1, Number(latestRuns?.count ?? 1));
  const runId = `run-${workRequestId}-retry-${retryNumber}`;
  const now = new Date().toISOString();
  const assignmentError = parseJson<Record<string, unknown>>(
    failedTask.assignmentErrorJson,
    {},
  );
  const assignmentErrorDetail =
    typeof assignmentError.error === "object" && assignmentError.error !== null
      ? (assignmentError.error as Record<string, unknown>)
      : {};
  const errorCode = canonicalExecutionErrorCode(
    assignmentErrorDetail.code ?? failedTask.error ?? "execution_failed",
  );
  const retryPolicy = {
    manualRetry: {
      stepKind,
      errorCode,
      retryNumber,
      ...(stepKind === "implement"
        ? { sessionStrategy: retrySessionStrategy }
        : {}),
    },
  };
  const reservation = await env.CONCLAVE_DB.prepare(
    "UPDATE work_requests SET status = 'queued', updated_at = ?1 WHERE id = ?2 AND status = 'failed'",
  )
    .bind(now, workRequestId)
    .run();
  if (reservation.meta.changes !== 1)
    throw new HttpError(409, "This Work Request is already being retried");
  try {
    await env.CONCLAVE_DB.batch([
      env.CONCLAVE_DB.prepare(
        `UPDATE workflow_tasks SET status = 'queued', output_json = NULL,
              error = NULL, started_at = NULL, finished_at = NULL, updated_at = ?1
        WHERE work_request_id = ?2 AND step_kind = ?3 AND status = 'failed'`,
      ).bind(now, workRequestId, stepKind),
      env.CONCLAVE_DB.prepare(
        `INSERT INTO runs
       (id, space_id, thread_id, work_request_id,
        policy_snapshot_json, status, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, 'created', ?6, ?6)`,
      ).bind(
        runId,
        spaceId,
        String(row.threadId),
        workRequestId,
        JSON.stringify(retryPolicy),
        now,
      ),
    ]);
  } catch (error) {
    await env.CONCLAVE_DB.prepare(
      "UPDATE work_requests SET status = 'failed', updated_at = ?1 WHERE id = ?2 AND status = 'queued'",
    )
      .bind(new Date().toISOString(), workRequestId)
      .run();
    throw error;
  }

  if (row.mode === "stateful") {
    if (!env.CONCLAVE_THREAD_COORDINATOR)
      throw new HttpError(503, "Thread runtime coordination is unavailable");
    const coordinator = env.CONCLAVE_THREAD_COORDINATOR.getByName(
      String(row.threadId),
    );
    const response = await coordinator.fetch(
      new Request("https://thread-coordinator/enqueue", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-thread-id": String(row.threadId),
        },
        body: JSON.stringify({ workRequestId }),
      }),
    );
    if (!response.ok)
      throw new HttpError(503, "Thread runtime coordination is unavailable");
  }

  await createOrGetRun(env, {
    runId,
    goalId: workRequestId,
    idempotencyKey: `${workRequestId}-retry-${retryNumber}`,
    organizationId: String(row.primaryWorkspaceId),
    workRequestId,
    threadId: String(row.threadId),
    spaceId,
    builtinWorkflow: workflow,
    input: attachmentInput,
    retryStepKind: stepKind as StepKind,
    ...(stepKind === "implement"
      ? { retrySessionStrategy: retrySessionStrategy as "resume" | "fresh" }
      : {}),
    retryNumber,
  });
  return json(
    { workRequestId, runId, stepKind, retryNumber, status: "queued" },
    { status: 202 },
  );
}

export async function handleGetWorkRequest(
  request: Request,
  env: SecurityEnv,
  workRequestId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT wr.id, wr.thread_id AS threadId,
            wr.requested_by_user_id AS requestedByUserId,
            (SELECT conversation_id FROM conversation_work_requests WHERE work_request_id = wr.id) AS conversationId,
            u.display_name AS requestedByName,
            wr.workflow_id AS workflowId, wr.workflow_version AS workflowVersion,
            wr.workflow_snapshot_json AS workflowSnapshotJson,
            (SELECT text FROM conversation_history_entries h WHERE h.work_request_id = wr.id AND h.kind = 'user_message' LIMIT 1) AS canonicalUserText, wr.input_json AS inputJson, wr.snapshot_json AS snapshotJson,
            wr.status, wr.created_at AS createdAt, wr.updated_at AS updatedAt
       FROM work_requests wr JOIN users u ON u.id = wr.requested_by_user_id
      WHERE wr.id = ?1`,
  )
    .bind(workRequestId)
    .first<Record<string, unknown>>();
  if (!row) throw new HttpError(404, "Work Request not found");
  await authorizeThreadAccess(
    request,
    env,
    String(row.threadId),
    "view",
    accessContext,
  );
  const task = await env.CONCLAVE_DB.prepare(
    `SELECT output_json AS outputJson, error
     FROM workflow_tasks WHERE work_request_id = ?1
     ORDER BY created_at DESC, id DESC LIMIT 1`,
  )
    .bind(workRequestId)
    .first<{ outputJson: string | null; error: string | null }>();
  let result: unknown = null;
  if (task?.outputJson) {
    try {
      result = JSON.parse(task.outputJson);
    } catch {
      result = null;
    }
  }
  const input = parseJson<Record<string, unknown>>(String(row.inputJson), {});
  const snapshot = parseJson<Record<string, unknown>>(
    String(row.snapshotJson),
    {},
  );
  const workflow = parseJson<Record<string, unknown>>(
    String(row.workflowSnapshotJson),
    {},
  );
  const latestRun = await env.CONCLAVE_DB.prepare(
    `SELECT policy_snapshot_json AS policySnapshotJson
       FROM runs WHERE work_request_id = ?1
      ORDER BY created_at DESC, id DESC LIMIT 1`,
  )
    .bind(workRequestId)
    .first<{ policySnapshotJson: string | null }>();
  const latestRunPolicy = parseJson<Record<string, unknown>>(
    latestRun?.policySnapshotJson,
    {},
  );
  const manualRetry =
    typeof latestRunPolicy.manualRetry === "object" &&
    latestRunPolicy.manualRetry !== null
      ? (latestRunPolicy.manualRetry as Record<string, unknown>)
      : {};
  const bindings =
    typeof snapshot.resolvedBindings === "object" &&
    snapshot.resolvedBindings !== null
      ? (snapshot.resolvedBindings as Record<string, unknown>)
      : {};
  const taskRows = await env.CONCLAVE_DB.prepare(
    `SELECT wt.id AS taskId, wt.step_kind AS kind, wt.status,
            wt.output_json AS outputJson, wt.error, wt.attempt,
            wt.started_at AS startedAt, wt.finished_at AS finishedAt,
            wa.id AS assignmentId, wa.workspace_worker_id AS workerId,
            wa.worker_type_id AS logicalWorkerTypeId, wa.model AS assignedModel,
            wa.engine_version AS engineVersion,
            wa.session_policy AS sessionPolicy,
            wa.created_at AS assignmentCreatedAt,
            wa.updated_at AS assignmentUpdatedAt,
            wa.permission_snapshot_json AS permissionSnapshotJson,
            wa.error_json AS assignmentErrorJson,
            wi.worker_type_id AS inventoryWorkerTypeId,
            wi.provider_tool_name AS configuredProviderToolName,
            wi.provider_tool_version AS configuredProviderToolVersion,
            worker_catalog.display_name AS workerDisplayName
       FROM workflow_tasks wt
       JOIN work_requests wr ON wr.id = wt.work_request_id
       LEFT JOIN worker_assignments wa ON wa.id = (
         SELECT wa2.id FROM worker_assignments wa2
          WHERE wa2.task_id = wt.id
          ORDER BY wa2.created_at DESC, wa2.id DESC LIMIT 1
       )
       LEFT JOIN workspace_worker_inventory wi ON wi.worker_id = COALESCE(
         wa.workspace_worker_id,
         json_extract(wr.snapshot_json, '$.resolvedBindings.' ||
           CASE WHEN wr.workflow_id = 'direct' THEN 'direct' ELSE wt.step_kind END || '.workerId')
       )
       LEFT JOIN worker_catalog
         ON worker_catalog.worker_type_id = COALESCE(
           wa.worker_type_id, wi.worker_type_id
         )
      WHERE wt.work_request_id = ?1
      ORDER BY wt.created_at, wt.id`,
  )
    .bind(workRequestId)
    .all<Record<string, unknown>>();
  const taskByKind = new Map(
    (taskRows.results ?? []).map((value) => [String(value.kind), value]),
  );
  const turns =
    (await loadConversationTurns(env.CONCLAVE_DB, [workRequestId])).get(
      workRequestId,
    ) ?? [];
  const workflowSteps = Array.isArray(workflow.steps) ? workflow.steps : [];
  const steps = workflowSteps
    .flatMap((value) => {
      if (!value || typeof value !== "object") return [];
      const definition = value as Record<string, unknown>;
      const kind = String(definition.kind ?? "implement");
      const task = taskByKind.get(kind);
      const bindingId = row.workflowId === "direct" ? "direct" : kind;
      const bindingValue = bindings[bindingId];
      const binding =
        typeof bindingValue === "object" && bindingValue !== null
          ? (bindingValue as Record<string, unknown>)
          : {};
      const output = parseJson<Record<string, unknown>>(
        typeof task?.outputJson === "string" ? task.outputJson : null,
        {},
      );
      const permissionSnapshot = parseJson<Record<string, unknown>>(
        typeof task?.permissionSnapshotJson === "string"
          ? task.permissionSnapshotJson
          : null,
        {},
      );
      const hasAssignment = typeof task?.assignmentId === "string";
      const assignmentError = parseJson<Record<string, unknown>>(
        typeof task?.assignmentErrorJson === "string"
          ? task.assignmentErrorJson
          : null,
        {},
      );
      const assignmentErrorValue = assignmentError.error;
      const assignmentErrorObject =
        typeof assignmentErrorValue === "object" &&
        assignmentErrorValue !== null
          ? (assignmentErrorValue as Record<string, unknown>)
          : {};
      const rawErrorCode =
        typeof assignmentErrorObject.code === "string"
          ? assignmentErrorObject.code
          : typeof task?.error === "string"
            ? task.error
            : null;
      const errorCode = rawErrorCode
        ? canonicalExecutionErrorCode(rawErrorCode)
        : null;
      const startedAt =
        (typeof task?.startedAt === "string" ? task.startedAt : null) ??
        (typeof output.startedAt === "string" ? output.startedAt : null) ??
        (typeof task?.assignmentCreatedAt === "string"
          ? task.assignmentCreatedAt
          : null);
      const finishedAt =
        (typeof task?.finishedAt === "string" ? task.finishedAt : null) ??
        (typeof output.completedAt === "string" ? output.completedAt : null) ??
        (typeof task?.assignmentUpdatedAt === "string" &&
        ["completed", "failed", "cancelled"].includes(String(task.status))
          ? task.assignmentUpdatedAt
          : null);
      const startMs = startedAt ? Date.parse(startedAt) : NaN;
      const endMs = finishedAt ? Date.parse(finishedAt) : Date.now();
      const elapsedMs = Number.isFinite(startMs)
        ? Math.max(0, endMs - startMs)
        : null;
      const resolvedWorkerId =
        typeof binding.workerId === "string" ? binding.workerId : null;
      return [
        {
          kind,
          status: String(
            task?.status ?? (row.status === "queued" ? "queued" : "waiting"),
          ),
          workerId: task?.workerId ?? resolvedWorkerId,
          workerTypeId: hasAssignment
            ? (task?.logicalWorkerTypeId ?? null)
            : (task?.inventoryWorkerTypeId ?? null),
          workerDisplayName:
            typeof task?.workerDisplayName === "string"
              ? task.workerDisplayName
              : null,
          engineVersion: hasAssignment
            ? typeof permissionSnapshot.profileDefinitionId === "string"
              ? (task?.engineVersion ?? null)
              : null
            : typeof output.engineVersion === "string"
              ? output.engineVersion
              : null,
          profileDefinitionId: hasAssignment
            ? typeof permissionSnapshot.profileDefinitionId === "string"
              ? permissionSnapshot.profileDefinitionId
              : null
            : null,
          profileReleaseVersion: hasAssignment
            ? Number.isSafeInteger(permissionSnapshot.profileReleaseVersion)
              ? permissionSnapshot.profileReleaseVersion
              : null
            : null,
          model: hasAssignment
            ? (task?.assignedModel ?? null)
            : typeof binding.model === "string"
              ? binding.model
              : null,
          providerToolName:
            (typeof permissionSnapshot.providerToolName === "string"
              ? permissionSnapshot.providerToolName
              : null) ??
            (hasAssignment ? null : task?.configuredProviderToolName) ??
            null,
          providerToolVersion:
            (typeof permissionSnapshot.providerToolVersion === "string"
              ? permissionSnapshot.providerToolVersion
              : null) ??
            (hasAssignment ? null : task?.configuredProviderToolVersion) ??
            (typeof output.providerToolVersion === "string"
              ? output.providerToolVersion
              : null),
          startedAt,
          completedAt: finishedAt,
          elapsedMs,
          resultText:
            typeof output.text === "string"
              ? output.text.slice(0, 24_000)
              : null,
          assignmentId:
            typeof task?.assignmentId === "string" ? task.assignmentId : null,
          sessionPolicy:
            typeof task?.sessionPolicy === "string" ? task.sessionPolicy : null,
          errorCode,
          errorMessage: errorCode ? executionErrorMessage(errorCode) : null,
          ...(manualRetry.stepKind === kind &&
          (manualRetry.sessionStrategy === "resume" ||
            manualRetry.sessionStrategy === "fresh")
            ? { retrySessionStrategy: manualRetry.sessionStrategy }
            : {}),
        },
      ];
    })
    .map((step) => withConversationTurn(step, turns));
  const errorCode =
    [...steps]
      .reverse()
      .map((step) => step.errorCode)
      .find((code) => code !== null) ?? null;
  const workflowRun =
    (await loadConversationWorkflowRuns(env.CONCLAVE_DB, [workRequestId])).get(
      workRequestId,
    ) ?? null;
  return json({
    workRequest: {
      workflowRun,
      turns,
      executionConfig: snapshot.turnExecutionConfig ?? null,
      conversationId: row.conversationId ?? null,
      id: String(row.id),
      requestedByUserId: String(row.requestedByUserId),
      requestedByName: String(row.requestedByName ?? "Team member"),
      status: String(row.status),
      workflowId: String(row.workflowId),
      workflowVersion: Number(row.workflowVersion),
      workflowName: historicalWorkflowName(
        workflow,
        row.workflowId,
        row.workflowVersion,
      ),
      originalRequest: String(
        row.canonicalUserText ?? input.originalRequest ?? input.request ?? "",
      ),
      createdAt: String(row.createdAt),
      updatedAt: String(row.updatedAt),
    },
    workflowSnapshot: workflow,
    steps,
    result,
    errorCode,
    errorMessage: errorCode ? executionErrorMessage(errorCode) : null,
  });
}

export async function handleListWorkRequests(
  request: Request,
  env: SecurityEnv,
  threadId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  await authorizeThreadAccess(request, env, threadId, "view", accessContext);
  const url = new URL(request.url);
  const rawLimit = Number(url.searchParams.get("limit") ?? 100);
  const limit = Number.isInteger(rawLimit)
    ? Math.min(100, Math.max(1, rawLimit))
    : 100;
  const beforeCreatedAt = url.searchParams.get("beforeCreatedAt");
  const beforeId = url.searchParams.get("beforeId");
  const activeOnly = url.searchParams.get("activeOnly") === "true";
  const recentCutoff = new Date(Date.now() - 15 * 60_000).toISOString();
  const page = await env.CONCLAVE_DB.prepare(
    `SELECT wr.id, wr.requested_by_user_id AS requestedByUserId,
            (SELECT conversation_id FROM conversation_work_requests WHERE work_request_id = wr.id) AS conversationId,
            u.display_name AS requestedByName, wr.workflow_id AS workflowId,
            wr.workflow_version AS workflowVersion,
            wr.workflow_snapshot_json AS workflowSnapshotJson,
            wr.snapshot_json AS snapshotJson, (SELECT text FROM conversation_history_entries h WHERE h.work_request_id = wr.id AND h.kind = 'user_message' LIMIT 1) AS canonicalUserText, wr.input_json AS inputJson,
            wr.status, wr.created_at AS createdAt, wr.updated_at AS updatedAt
       FROM work_requests wr
       JOIN users u ON u.id = wr.requested_by_user_id
      WHERE wr.thread_id = ?1
        AND (?2 IS NULL OR wr.created_at < ?2 OR (wr.created_at = ?2 AND wr.id < ?3))
        AND (?4 = 0 OR wr.status IN ('queued', 'running', 'waiting') OR wr.updated_at >= ?5)
      ORDER BY wr.created_at DESC, wr.id DESC LIMIT ?6`,
  )
    .bind(
      threadId,
      beforeCreatedAt,
      beforeId,
      activeOnly ? 1 : 0,
      recentCutoff,
      limit,
    )
    .all<Record<string, unknown>>();
  const requests = page.results ?? [];
  if (requests.length === 0)
    return json({ workRequests: [], nextCursor: null });
  const ids = requests.map((row) => String(row.id));
  const turnsByRequest = await loadConversationTurns(env.CONCLAVE_DB, ids);
  const workflowRunsByRequest = await loadConversationWorkflowRuns(
    env.CONCLAVE_DB,
    ids,
  );
  const placeholders = ids.map((_, index) => `?${index + 1}`).join(", ");
  const desiredWorkerIds = new Set<string>();
  for (const row of requests) {
    const requestSnapshot = parseJson<Record<string, unknown>>(
      typeof row.snapshotJson === "string" ? row.snapshotJson : null,
      {},
    );
    const requestBindings = requestSnapshot.resolvedBindings;
    if (typeof requestBindings !== "object" || requestBindings === null)
      continue;
    for (const value of Object.values(requestBindings)) {
      if (
        typeof value === "object" &&
        value !== null &&
        typeof (value as Record<string, unknown>).workerId === "string"
      ) {
        desiredWorkerIds.add(
          (value as Record<string, unknown>).workerId as string,
        );
      }
    }
  }
  const desiredWorkers = new Map<string, Record<string, unknown>>();
  if (desiredWorkerIds.size > 0) {
    const workerPlaceholders = [...desiredWorkerIds]
      .map((_, index) => `?${index + 1}`)
      .join(", ");
    const workerRows = await env.CONCLAVE_DB.prepare(
      `SELECT worker_id AS workerId, worker_type_id AS workerTypeId,
              engine_version AS engineVersion,
              profile_definition_id AS profileDefinitionId,
              profile_release_version AS profileReleaseVersion,
              provider_tool_name AS providerToolName,
              provider_tool_version AS providerToolVersion
         FROM workspace_worker_inventory WHERE worker_id IN (${workerPlaceholders})`,
    )
      .bind(...desiredWorkerIds)
      .all<Record<string, unknown>>();
    for (const worker of workerRows.results ?? []) {
      desiredWorkers.set(String(worker.workerId), worker);
    }
  }
  const taskRows = await env.CONCLAVE_DB.prepare(
    `SELECT wt.work_request_id AS workRequestId, wt.step_kind AS kind,
            wt.status, wt.output_json AS outputJson, wt.error,
            COALESCE(wt.started_at, wt.created_at) AS startedAt,
            COALESCE(wt.finished_at, wt.updated_at) AS updatedAt,
            wa.error_json AS assignmentErrorJson,
            wa.id AS assignmentId, wa.workspace_worker_id AS workerId,
            wa.worker_type_id AS logicalWorkerTypeId,
            wa.model AS assignedModel,
            wa.engine_version AS engineVersion,
            wa.permission_snapshot_json AS permissionSnapshotJson,
            wi.worker_type_id AS inventoryWorkerTypeId,
            wi.provider_tool_name AS configuredProviderToolName,
            wi.provider_tool_version AS configuredProviderToolVersion
       FROM workflow_tasks wt
       JOIN work_requests wr ON wr.id = wt.work_request_id
       LEFT JOIN worker_assignments wa ON wa.id = (
         SELECT wa2.id FROM worker_assignments wa2
          WHERE wa2.task_id = wt.id
          ORDER BY wa2.created_at DESC, wa2.id DESC LIMIT 1
       )
       LEFT JOIN workspace_worker_inventory wi ON wi.worker_id = COALESCE(
         wa.workspace_worker_id,
         json_extract(wr.snapshot_json, '$.resolvedBindings.' ||
           CASE WHEN wr.workflow_id = 'direct' THEN 'direct' ELSE wt.step_kind END || '.workerId')
       )
      WHERE wt.work_request_id IN (${placeholders})
      ORDER BY wt.created_at, wt.id`,
  )
    .bind(...ids)
    .all<Record<string, unknown>>();
  const tasksByRequest = new Map<string, Record<string, unknown>[]>();
  for (const task of taskRows.results ?? []) {
    const key = String(task.workRequestId);
    const values = tasksByRequest.get(key) ?? [];
    values.push(task);
    tasksByRequest.set(key, values);
  }
  const workRequests = requests.map((row) => {
    const id = String(row.id);
    const input = parseJson<Record<string, unknown>>(String(row.inputJson), {});
    const workflow = parseJson<Record<string, unknown>>(
      String(row.workflowSnapshotJson),
      {},
    );
    const snapshot = parseJson<Record<string, unknown>>(
      typeof row.snapshotJson === "string" ? row.snapshotJson : null,
      {},
    );
    const bindings =
      typeof snapshot.resolvedBindings === "object" &&
      snapshot.resolvedBindings !== null
        ? (snapshot.resolvedBindings as Record<string, unknown>)
        : {};
    const persistedTasks = tasksByRequest.get(id) ?? [];
    const taskByKind = new Map(
      persistedTasks.map((task) => [String(task.kind), task]),
    );
    const workflowSteps = Array.isArray(workflow.steps) ? workflow.steps : [];
    const steps = workflowSteps
      .flatMap((value) => {
        if (!value || typeof value !== "object") return [];
        const definition = value as Record<string, unknown>;
        const kind = String(definition.kind ?? "implement");
        const task = taskByKind.get(kind);
        const bindingId = row.workflowId === "direct" ? "direct" : kind;
        const bindingValue = bindings[bindingId];
        const binding =
          typeof bindingValue === "object" && bindingValue !== null
            ? (bindingValue as Record<string, unknown>)
            : {};
        const desiredWorker =
          typeof binding.workerId === "string"
            ? desiredWorkers.get(binding.workerId)
            : undefined;
        const output =
          typeof task?.outputJson === "string"
            ? parseJson<Record<string, unknown>>(task.outputJson, {})
            : {};
        const permissionSnapshot = parseJson<Record<string, unknown>>(
          typeof task?.permissionSnapshotJson === "string"
            ? task.permissionSnapshotJson
            : null,
          {},
        );
        const hasAssignment = typeof task?.workerId === "string";
        const testSummary =
          kind === "test" && typeof output.text === "string"
            ? summarizeTestCounts(output.text)
            : null;
        const assignmentError = parseJson<Record<string, unknown>>(
          typeof task?.assignmentErrorJson === "string"
            ? task.assignmentErrorJson
            : null,
          {},
        );
        const assignmentErrorValue = assignmentError.error;
        const assignmentErrorDetail =
          typeof assignmentErrorValue === "object" &&
          assignmentErrorValue !== null
            ? (assignmentErrorValue as Record<string, unknown>)
            : {};
        const stableErrorCode =
          typeof assignmentErrorDetail.code === "string"
            ? canonicalExecutionErrorCode(assignmentErrorDetail.code)
            : typeof task?.error === "string"
              ? canonicalExecutionErrorCode(task.error)
              : null;
        const created = task?.startedAt
          ? Date.parse(String(task.startedAt))
          : NaN;
        const updated = task?.updatedAt
          ? Date.parse(String(task.updatedAt))
          : Date.now();
        const finished = ["completed", "failed", "cancelled"].includes(
          String(task?.status),
        );
        return [
          {
            kind,
            assignmentId:
              typeof task?.assignmentId === "string" ? task.assignmentId : null,
            status: String(
              task?.status ?? (row.status === "queued" ? "queued" : "waiting"),
            ),
            workerId: task?.workerId ?? binding.workerId ?? null,
            workerTypeId: hasAssignment
              ? (task?.logicalWorkerTypeId ?? null)
              : (task?.inventoryWorkerTypeId ??
                desiredWorker?.workerTypeId ??
                null),
            engineVersion: hasAssignment
              ? typeof permissionSnapshot.profileDefinitionId === "string"
                ? (task?.engineVersion ?? null)
                : null
              : (desiredWorker?.engineVersion ?? null),
            profileDefinitionId: hasAssignment
              ? typeof permissionSnapshot.profileDefinitionId === "string"
                ? permissionSnapshot.profileDefinitionId
                : null
              : (desiredWorker?.profileDefinitionId ?? null),
            profileReleaseVersion: hasAssignment
              ? Number.isSafeInteger(permissionSnapshot.profileReleaseVersion)
                ? permissionSnapshot.profileReleaseVersion
                : null
              : (desiredWorker?.profileReleaseVersion ?? null),
            model: hasAssignment
              ? (task?.assignedModel ?? null)
              : typeof binding.model === "string"
                ? binding.model
                : null,
            providerToolName:
              (typeof permissionSnapshot.providerToolName === "string"
                ? permissionSnapshot.providerToolName
                : null) ??
              (hasAssignment ? null : task?.configuredProviderToolName) ??
              desiredWorker?.providerToolName ??
              null,
            providerToolVersion:
              (typeof permissionSnapshot.providerToolVersion === "string"
                ? permissionSnapshot.providerToolVersion
                : null) ??
              (hasAssignment ? null : task?.configuredProviderToolVersion) ??
              desiredWorker?.providerToolVersion ??
              null,
            startedAt: task?.startedAt ?? null,
            updatedAt: task?.updatedAt ?? null,
            elapsedMs: Number.isFinite(created)
              ? Math.max(0, (finished ? updated : Date.now()) - created)
              : null,
            finalText: typeof output.text === "string" ? output.text : null,
            ...(testSummary ? { testSummary } : {}),
            errorCode: stableErrorCode,
            errorMessage: stableErrorCode
              ? executionErrorMessage(stableErrorCode)
              : null,
            error: typeof task?.error === "string" ? task.error : null,
          },
        ];
      })
      .map((step) => withConversationTurn(step, turnsByRequest.get(id) ?? []));
    const terminalStep = steps.at(-1);
    const finalText =
      row.status === "completed" && terminalStep?.status === "completed"
        ? terminalStep.finalText
        : null;
    const stepError = [...steps]
      .reverse()
      .map((step) => step.error)
      .find(
        (error): error is string =>
          typeof error === "string" && error.length > 0,
      );
    const errorCode = stepError ? canonicalExecutionErrorCode(stepError) : null;
    return {
      id,
      conversationId: row.conversationId ?? null,
      requestedByName: String(row.requestedByName ?? "Team member"),
      turns: turnsByRequest.get(id) ?? [],
      workflowRun: workflowRunsByRequest.get(id) ?? null,
      executionConfig: snapshot.turnExecutionConfig ?? null,
      prompt: String(
        row.canonicalUserText ?? input.originalRequest ?? input.request ?? "",
      ),
      workflowId: String(row.workflowId),
      workflowVersion: Number(row.workflowVersion),
      workflowName: historicalWorkflowName(
        workflow,
        row.workflowId,
        row.workflowVersion,
      ),
      status: String(row.status),
      createdAt: String(row.createdAt),
      updatedAt: String(row.updatedAt),
      steps: steps.map(({ finalText: _text, error: _error, ...step }) => step),
      ...(finalText ? { finalText } : {}),
      ...(errorCode
        ? {
            errorCode,
            error:
              "A Step could not be completed. Open Run details for the safe error code.",
          }
        : {}),
    };
  });
  const last = requests.at(-1)!;
  return json({
    workRequests,
    nextCursor:
      requests.length === limit
        ? { createdAt: String(last.createdAt), id: String(last.id) }
        : null,
  });
}

export async function handleCancelWorkRequest(
  request: Request,
  env: SecurityEnv,
  workRequestId: string,
  accessContext?: ExecutionContext,
): Promise<Response> {
  const row = await env.CONCLAVE_DB.prepare(
    "SELECT thread_id AS threadId, mode, status, cancel_requested_at AS cancelRequestedAt FROM work_requests WHERE id = ?1",
  )
    .bind(workRequestId)
    .first<{
      threadId: string;
      mode: string;
      status: string;
      cancelRequestedAt: string | null;
    }>();
  if (!row) throw new HttpError(404, "Work Request not found");
  await authorizeThreadAccess(
    request,
    env,
    row.threadId,
    "execute",
    accessContext,
  );
  if (row.status === "cancelled")
    return json({ workRequestId, status: "cancelled" });
  if (row.status === "failed") {
    const now = new Date().toISOString();
    await env.CONCLAVE_DB.batch([
      env.CONCLAVE_DB.prepare(
        "UPDATE work_requests SET status = 'cancelled', updated_at = ?1 WHERE id = ?2 AND status = 'failed'",
      ).bind(now, workRequestId),
      env.CONCLAVE_DB.prepare(
        `UPDATE runs SET status = 'cancelled', finished_at = ?1, updated_at = ?1
          WHERE id = (SELECT id FROM runs WHERE work_request_id = ?2 AND status = 'failed'
                     ORDER BY created_at DESC, id DESC LIMIT 1)`,
      ).bind(now, workRequestId),
      env.CONCLAVE_DB.prepare(
        `UPDATE workflow_tasks SET status = 'cancelled', finished_at = ?1, updated_at = ?1
          WHERE work_request_id = ?2 AND status IN ('queued', 'waiting')`,
      ).bind(now, workRequestId),
    ]);
    return json({ workRequestId, status: "cancelled" });
  }
  if (row.status === "queued" && row.mode === "stateful") {
    if (!env.CONCLAVE_THREAD_COORDINATOR)
      throw new HttpError(503, "Thread execution coordinator unavailable");
    const coordinator = env.CONCLAVE_THREAD_COORDINATOR.getByName(row.threadId);
    return coordinator.fetch(
      new Request("https://thread-coordinator/cancel", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-thread-id": row.threadId,
        },
        body: JSON.stringify({ workRequestId }),
      }),
    );
  }
  if (row.status === "queued") {
    const now = new Date().toISOString();
    await env.CONCLAVE_DB.batch([
      env.CONCLAVE_DB.prepare(
        "UPDATE work_requests SET status = 'cancelled', updated_at = ?1 WHERE id = ?2 AND status = 'queued'",
      ).bind(now, workRequestId),
      env.CONCLAVE_DB.prepare(
        "UPDATE runs SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status = 'created'",
      ).bind(now, workRequestId),
      env.CONCLAVE_DB.prepare(
        "UPDATE workflow_tasks SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status IN ('queued', 'waiting')",
      ).bind(now, workRequestId),
    ]);
    return json({ workRequestId, status: "cancelled" });
  }
  if (row.status !== "running")
    throw new HttpError(409, "This Work Request cannot be cancelled");

  const requestedAt = row.cancelRequestedAt ?? new Date().toISOString();
  await env.CONCLAVE_DB.prepare(
    "UPDATE work_requests SET cancel_requested_at = COALESCE(cancel_requested_at, ?1), updated_at = ?1 WHERE id = ?2 AND status = 'running'",
  )
    .bind(requestedAt, workRequestId)
    .run();

  const active = await env.CONCLAVE_DB.prepare(
    `SELECT wa.id AS assignmentId, wa.execution_workspace_id AS workspaceId,
            wa.status AS assignmentStatus
       FROM workflow_tasks wt
       JOIN worker_assignments wa ON wa.task_id = wt.id
      WHERE wt.work_request_id = ?1 AND wt.status = 'running'
        AND wa.status IN ('created', 'dispatched', 'acknowledged', 'running')
      ORDER BY wa.created_at DESC LIMIT 1`,
  )
    .bind(workRequestId)
    .first<{
      assignmentId: string;
      workspaceId: string;
      assignmentStatus: string;
    }>();
  if (active) {
    const cancellation = await cancelTaskAssignment(
      env as unknown as AssignmentDispatcherEnv,
      active.workspaceId,
      active.assignmentId,
      "Work Request cancelled from Work chat",
    );
    if (!cancellation.cancelled)
      throw new HttpError(
        503,
        "Workspace did not confirm that the Worker process tree stopped. The Run remains active; retry cancellation.",
      );
  }

  const now = new Date().toISOString();
  await env.CONCLAVE_DB.batch([
    env.CONCLAVE_DB.prepare(
      "UPDATE work_requests SET status = 'cancelled', updated_at = ?1 WHERE id = ?2 AND status = 'running'",
    ).bind(now, workRequestId),
    env.CONCLAVE_DB.prepare(
      "UPDATE runs SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status IN ('created', 'running')",
    ).bind(now, workRequestId),
    env.CONCLAVE_DB.prepare(
      "UPDATE workflow_tasks SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status IN ('queued', 'waiting')",
    ).bind(now, workRequestId),
  ]);
  if (!active) {
    await env.CONCLAVE_DB.prepare(
      "UPDATE workflow_tasks SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE work_request_id = ?2 AND status = 'running'",
    )
      .bind(now, workRequestId)
      .run();
    const run = await env.CONCLAVE_DB.prepare(
      "SELECT id FROM runs WHERE work_request_id = ?1 ORDER BY created_at DESC LIMIT 1",
    )
      .bind(workRequestId)
      .first<{ id: string }>();
    if (run && env.CONCLAVE_RUN_WORKFLOW) {
      const instanceId = await resolveWorkflowInstanceId(env, run.id);
      const instance = await env.CONCLAVE_RUN_WORKFLOW.get(instanceId);
      await instance.terminate();
    }
  }
  return json({ workRequestId, status: "cancelled" });
}
