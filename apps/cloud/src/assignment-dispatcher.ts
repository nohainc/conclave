import { loadConversationBootstrap } from "./routes/conversation-bootstrap.js";
import { createHash } from "node:crypto";
import {
  type AssignmentResultPayload,
  type AssignmentFailurePayload,
  type AssignmentCancelPayload,
} from "@conclave/workspace-runtime-protocol";
import type { ThreadBindingId } from "@conclave/core";
import {
  canonicalExecutionErrorCode,
  executionErrorMessage,
} from "@conclave/protocol";
import {
  selectSpaceExecutionTarget,
  type ExecutionTarget,
} from "./scheduler.js";
import { recordExecutionWorkspaceAudit } from "./workspace-audit.js";

/** Conclave scope reference only; does not expose or certify a native CLI thread. */
export function conversationWorkerSessionReference(
  target: Pick<
    ExecutionTarget,
    | "workspaceId"
    | "workerId"
    | "profileDefinitionId"
    | "profileReleaseVersion"
    | "conversationId"
  >,
  sessionPolicy: string,
  sessionKey: unknown,
): string | null {
  return sessionPolicy === "durable_session"
    ? `worker-session-${createHash("sha256")
        .update(
          JSON.stringify([
            target.workspaceId,
            target.workerId,
            target.profileDefinitionId,
            target.conversationId ?? null,
            sessionKey,
          ]),
        )
        .digest("hex")}`
    : null;
}

export interface TaskToDispatch {
  readonly id: string;
  readonly role: string;
  readonly objective: string;
  readonly capabilities?: readonly string[];
  readonly input?: Record<string, unknown>;
  readonly contextArtifactIds?: readonly string[];
  readonly timeoutMs?: number;
  /** Conclave logical execution-session policy; never provider-specific. */
  readonly sessionPolicy?: unknown;
  /** Opaque Conclave key used only for package-local session mapping. */
  readonly sessionKey?: unknown;
  readonly spaceId?: string;
  readonly requestedByUserId?: string;
  readonly model?: string;
  readonly reasoningEffort?: string;
  readonly requiresIndependentVerification?: boolean;
  readonly threadId?: string;
  readonly workRequestId?: string;
  readonly workBindingId?: ThreadBindingId;
  readonly leaseId?: string;
  readonly fencingToken?: number;
  readonly executionClass?: "stateless_read" | "stateful_thread";
  /** Restricts Worker/provider access while retaining a Thread lease. */
  readonly readOnly?: boolean;
}

export interface DispatchAssignmentParams {
  readonly workspaceId: string;
  readonly runId: string;
  readonly taskId: string;
  readonly task: TaskToDispatch;
  readonly explicitWorkerId?: string;
  readonly explicitAttemptNumber?: number;
  readonly excludeIndependenceKeys?: readonly string[];
}

export interface DispatchAssignmentResult {
  readonly assignmentId: string;
  readonly attemptId: string;
  readonly workerId: string;
  readonly workspaceRuntimeId: string;
  readonly workerCatalogId: string;
  readonly status: "dispatched" | "failed" | "cancelled";
  readonly accepted: boolean;
  readonly error?: string;
}

export interface AssignmentDispatcherEnv {
  readonly CONCLAVE_DB: D1Database;
  readonly CONCLAVE_WORKSPACE_GATEWAY?: DurableObjectNamespace;
}

/**
 * Selects an eligible, online worker matching task requirements, capacity, and anti-collusion constraints.
 */
async function dispatchWorkspaceWorkerAssignment(
  env: AssignmentDispatcherEnv,
  params: DispatchAssignmentParams,
): Promise<DispatchAssignmentResult> {
  const { runId, taskId, task } = params;
  const target = await selectSpaceExecutionTarget(
    env.CONCLAVE_DB,
    {
      spaceId: task.spaceId!,
      requesterUserId: task.requestedByUserId!,
      role: task.role,
      capabilities: task.capabilities ?? [],
      workspaceId: params.workspaceId || undefined,
      workerId: params.explicitWorkerId,
      excludeIndependenceKeys: params.excludeIndependenceKeys,
      model: task.model,
      reasoningEffort: task.reasoningEffort,
      executionClass: task.executionClass,
      readOnly: task.readOnly,
      threadId: task.threadId,
      workRequestId: task.workRequestId,
      workBindingId: task.workBindingId,
    },
    new Date(),
    async (workspaceId, runtimeIdentityId) => {
      const gatewayNamespace = env.CONCLAVE_WORKSPACE_GATEWAY;
      if (!gatewayNamespace) return false;
      const gateway = gatewayNamespace.get(
        gatewayNamespace.idFromName(workspaceId),
      );
      const response = await gateway.fetch("http://gateway/status");
      if (!response.ok) return false;
      const status = (await response.json()) as {
        online?: boolean;
        // `online` describes the logical runtime session. Transport is
        // diagnostic only; both WebSocket and long-poll are dispatchable.
        activeTransport?: "websocket" | "http_long_poll" | null;
        workspaceRuntimeId?: string | null;
        executionWorkspaceId?: string | null;
      };
      return (
        status.online === true &&
        status.workspaceRuntimeId === runtimeIdentityId &&
        status.executionWorkspaceId === workspaceId
      );
    },
  );
  if (!target) {
    return {
      assignmentId: "",
      attemptId: "",
      workerId: "",
      workspaceRuntimeId: "",
      workerCatalogId: "",
      status: "failed",
      accepted: false,
      error:
        "No Workspace-owned Worker satisfied the active Workspace Grant, execution policy, readiness, capacity, and permission filters",
    };
  }
  const now = new Date().toISOString();
  const attemptNumber = params.explicitAttemptNumber ?? 1;
  const randomPart = crypto.randomUUID().slice(0, 8);
  const attemptId = `att-${taskId}-${attemptNumber}-${Date.now()}-${randomPart}`;
  const assignmentId = `asg-${taskId}-${attemptNumber}-${Date.now()}-${randomPart}`;
  const idempotencyKey = `idem-${assignmentId}`;
  const timeoutMs = task.timeoutMs || 15 * 60_000;
  const sessionPolicy = task.sessionPolicy as string;
  const sessionKey = task.sessionKey;
  const assignmentInput = { ...(task.input ?? {}) };
  delete assignmentInput.sessionPolicy;
  delete assignmentInput.sessionKey;
  let bootstrap;
  if (target.conversationId) {
    const requestId = target.workRequestId ?? task.workRequestId;
    if (!requestId)
      throw new Error("Conversation bootstrap requires a Work request");
    bootstrap = await loadConversationBootstrap(
      env.CONCLAVE_DB,
      target.conversationId,
      requestId,
      target.baseContextRevision ?? 0,
      sessionPolicy === "stateless" ? "stateless" : "bootstrap",
      taskId,
    );
  }
  const snapshot = {
    ...target.permissionSnapshot,
    ...(bootstrap
      ? {
          contextSnapshot: {
            schemaVersion: 1,
            baseContextRevision: bootstrap.contextRevision,
            turnRevision: bootstrap.turnRevision,
            throughSequence: bootstrap.throughSequence,
            digest: createHash("sha256").update(bootstrap.text).digest("hex"),
          },
        }
      : {}),
    selectionExplanation: target.selectionExplanation,
    baseContextRevision: target.baseContextRevision ?? 0,
    workerSessionId: conversationWorkerSessionReference(
      target,
      sessionPolicy,
      sessionKey,
    ),
  };
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO worker_assignments
       (id, space_id, execution_workspace_id, workspace_space_grant_id,
        run_id, task_id, attempt_id, requested_by_user_id, runtime_identity_id,
        worker_type_id, workspace_worker_id, engine_version,
        model, config_json, effective_permissions_json,
        permission_snapshot_json, timeout_ms, session_policy, idempotency_key, status,
        input_json, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
             ?13, ?14, ?15, ?16, ?17, ?18, ?19, 'created', ?20, ?21, ?21)`,
  )
    .bind(
      assignmentId,
      target.spaceId,
      target.workspaceId,
      target.workspaceSpaceGrantId,
      runId,
      taskId,
      attemptId,
      task.requestedByUserId,
      target.workspaceRuntimeIdentityId,
      target.workerTypeId,
      target.workerId,
      target.engineVersion,
      target.model,
      JSON.stringify(assignmentInput),
      JSON.stringify(target.effectivePermissions),
      JSON.stringify(snapshot),
      timeoutMs,
      sessionPolicy,
      idempotencyKey,
      JSON.stringify(assignmentInput),
      now,
    )
    .run();
  const workRequestId = target.workRequestId ?? task.workRequestId;
  if (workRequestId) {
    const cancellation = await env.CONCLAVE_DB.prepare(
      "SELECT cancel_requested_at FROM work_requests WHERE id = ?1 AND status IN ('running', 'cancelled')",
    )
      .bind(workRequestId)
      .first<{ cancel_requested_at: string | null }>();
    if (cancellation?.cancel_requested_at) {
      await recordAssignmentCancelled(env.CONCLAVE_DB, assignmentId, {
        status: "cancelled",
        reason: "Work Request cancellation was requested before dispatch",
      });
      return {
        assignmentId,
        attemptId,
        workerId: target.workerId,
        workspaceRuntimeId: target.workspaceRuntimeIdentityId,
        workerCatalogId: target.workerTypeId,
        status: "cancelled",
        accepted: false,
        error: "Work assignment cancelled before dispatch",
      };
    }
  }
  const workspaceOwner = await env.CONCLAVE_DB.prepare(
    "SELECT owner_user_id FROM execution_workspaces WHERE id = ?1",
  )
    .bind(target.workspaceId)
    .first<{ owner_user_id: string }>();
  if (workspaceOwner) {
    await recordExecutionWorkspaceAudit(env.CONCLAVE_DB, {
      workspaceId: target.workspaceId,
      ownerUserId: workspaceOwner.owner_user_id,
      actorType: "user",
      actorId: task.requestedByUserId!,
      action: "execution.assignment.dispatched",
      targetType: "worker_assignment",
      targetId: assignmentId,
      details: {
        spaceId: target.spaceId,
        workerId: target.workerId,
        grantId: target.workspaceSpaceGrantId,
      },
    });
  }
  await env.CONCLAVE_DB.prepare(
    "UPDATE workflow_tasks SET status = 'running', started_at = COALESCE(started_at, ?1), updated_at = ?1 WHERE id = ?2 AND status IN ('queued', 'waiting')",
  )
    .bind(now, taskId)
    .run();
  const payload = {
    snapshot: {
      assignmentId,
      objective: task.objective,
      role: task.role,
      contextArtifactIds: task.contextArtifactIds ?? [],
      threadId: target.threadId ?? task.threadId,
      workRequestId: target.workRequestId ?? task.workRequestId,
      leaseId: target.leaseId ?? task.leaseId,
      fencingToken: target.fencingToken ?? task.fencingToken,
      executionClass: target.executionClass,
      readOnly: target.readOnly,
      executionWorkspaceId: target.workspaceId,
      workspaceRuntimeId: target.workspaceRuntimeIdentityId,
      spaceId: target.spaceId,
      runId,
      taskId,
      attemptId,
      requestedByUserId: task.requestedByUserId,
      workerId: target.workerId,
      workerTypeId: target.workerTypeId,
      engineVersion: target.engineVersion,
      profileDefinitionId: target.profileDefinitionId,
      profileReleaseVersion: target.profileReleaseVersion,
      providerToolName: target.providerToolName,
      providerToolVersion: target.providerToolVersion,
      model: target.model,
      reasoningEffort: target.reasoningEffort ?? task.reasoningEffort ?? null,
      config: assignmentInput,
      permissions: target.effectivePermissions,
      permissionSnapshot: snapshot,
      contextRefs: (task.contextArtifactIds ?? []).map((artifactId) => ({
        artifactId,
      })),
      timeoutMs,
      sessionPolicy,
      ...(sessionKey !== undefined ? { sessionKey } : {}),
      ...(target.conversationId && sessionPolicy === "durable_session"
        ? {
            workerSession: {
              schemaVersion: 1,
              id: snapshot.workerSessionId,
              conversationId: target.conversationId,
              workerId: target.workerId,
              baseContextRevision: target.baseContextRevision ?? 0,
              ...(bootstrap ? { bootstrap } : {}),
            },
          }
        : {}),
      ...(bootstrap && sessionPolicy === "stateless"
        ? { statelessContext: bootstrap }
        : {}),
      idempotencyKey,
    },
    input: assignmentInput,
  };
  if (!env.CONCLAVE_WORKSPACE_GATEWAY) {
    const code = "provider_unavailable";
    const error = executionErrorMessage(code);
    await recordAssignmentError(env.CONCLAVE_DB, assignmentId, {
      error: {
        code,
        message: error,
        retryable: true,
      },
      failedAt: now,
    });
    return {
      assignmentId,
      attemptId,
      workerId: target.workerId,
      workspaceRuntimeId: target.workspaceRuntimeIdentityId,
      workerCatalogId: target.workerTypeId,
      status: "failed",
      accepted: false,
      error,
    };
  }
  try {
    const stub = env.CONCLAVE_WORKSPACE_GATEWAY.get(
      env.CONCLAVE_WORKSPACE_GATEWAY.idFromName(target.workspaceId),
    );
    // Dispatch through the Workspace Gateway's logical outbound path. The
    // Gateway writes to its active WebSocket or long-poll event queue.
    const response = await stub.fetch("http://gateway/dispatch-assignment", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        executionWorkspaceId: target.workspaceId,
        workspaceRuntimeId: target.workspaceRuntimeIdentityId,
        workerId: target.workerId,
        runId,
        taskId,
        attemptId,
        assignmentId,
        idempotencyKey,
        payload,
      }),
    });
    if (!response.ok)
      throw new Error(
        (await response.text()) || `Gateway returned HTTP ${response.status}`,
      );
    await env.CONCLAVE_DB.prepare(
      "UPDATE worker_assignments SET status = 'dispatched', updated_at = ?1 WHERE id = ?2 AND status = 'created'",
    )
      .bind(new Date().toISOString(), assignmentId)
      .run();
  } catch {
    const code = "provider_unavailable";
    const message = executionErrorMessage(code);
    await recordAssignmentError(env.CONCLAVE_DB, assignmentId, {
      error: { code, message, retryable: true },
      failedAt: new Date().toISOString(),
    });
    return {
      assignmentId,
      attemptId,
      workerId: target.workerId,
      workspaceRuntimeId: target.workspaceRuntimeIdentityId,
      workerCatalogId: target.workerTypeId,
      status: "failed",
      accepted: false,
      error: message,
    };
  }
  return {
    assignmentId,
    attemptId,
    workerId: target.workerId,
    workspaceRuntimeId: target.workspaceRuntimeIdentityId,
    workerCatalogId: target.workerTypeId,
    status: "dispatched",
    accepted: true,
  };
}

/**
 * Creates a Worker Assignment in D1 and dispatches the workflow step over the Workspace Gateway.
 */
export async function dispatchTaskAssignment(
  env: AssignmentDispatcherEnv,
  params: DispatchAssignmentParams,
): Promise<DispatchAssignmentResult> {
  const { task } = params;
  const sessionPolicy =
    task.sessionPolicy ?? task.input?.sessionPolicy ?? "stateless";
  const sessionKey = task.sessionKey ?? task.input?.sessionKey;
  if (
    !["stateless", "durable_session"].includes(String(sessionPolicy)) ||
    (sessionPolicy === "stateless" && sessionKey !== undefined) ||
    (sessionPolicy === "durable_session" &&
      (typeof sessionKey !== "string" ||
        !sessionKey.trim() ||
        sessionKey.length > 256))
  ) {
    return {
      assignmentId: "",
      attemptId: "",
      workerId: "",
      workspaceRuntimeId: "",
      workerCatalogId: "",
      status: "failed",
      accepted: false,
      error: "Assignment session policy or logical session key is invalid",
    };
  }
  const normalizedTask: TaskToDispatch = {
    ...task,
    sessionPolicy,
    ...(sessionKey !== undefined ? { sessionKey } : {}),
  };
  // Every assignment carries the authenticated Space requester so Workspace
  // selection, grants, and the immutable assignment target are evaluated.
  if (!normalizedTask.spaceId || !normalizedTask.requestedByUserId) {
    return {
      assignmentId: "",
      attemptId: "",
      workerId: "",
      workspaceRuntimeId: "",
      workerCatalogId: "",
      status: "failed",
      accepted: false,
      error: "Space execution context is required for assignment dispatch",
    };
  }
  return dispatchWorkspaceWorkerAssignment(env, {
    ...params,
    task: normalizedTask,
  });
}

/**
 * Records successful completion of an assignment, updating assignment, attempt, and task in D1.
 */
export async function recordAssignmentResult(
  db: D1Database,
  assignmentId: string,
  result: AssignmentResultPayload,
): Promise<void> {
  const now = new Date().toISOString();

  const existing = await db
    .prepare(`SELECT status, task_id FROM worker_assignments WHERE id = ?1`)
    .bind(assignmentId)
    .first<{
      status: string;
      task_id: string;
    }>();
  if (!existing || existing.status === "completed") return;
  if (existing.status === "failed" || existing.status === "cancelled") return;

  // 1. Update assignment
  await db
    .prepare(
      `UPDATE worker_assignments SET status = 'completed', output_json = ?1, updated_at = ?2 WHERE id = ?3`,
    )
    .bind(JSON.stringify(result), now, assignmentId)
    .run();

  await db
    .prepare(
      "UPDATE workflow_tasks SET status = 'completed', output_json = ?1, finished_at = ?2, updated_at = ?2 WHERE id = ?3",
    )
    .bind(JSON.stringify(result), now, existing.task_id)
    .run();
}

/**
 * Records failure of an assignment, updating assignment, attempt, and task in D1.
 */
export async function recordAssignmentError(
  db: D1Database,
  assignmentId: string,
  failure: AssignmentFailurePayload,
): Promise<void> {
  const now = new Date().toISOString();
  const code = canonicalExecutionErrorCode(failure.error?.code);
  const normalizedFailure: AssignmentFailurePayload = {
    error: {
      code,
      message: executionErrorMessage(code),
      retryable: failure.error?.retryable === true,
    },
    failedAt: now,
  };

  const existing = await db
    .prepare(`SELECT status, task_id FROM worker_assignments WHERE id = ?1`)
    .bind(assignmentId)
    .first<{
      status: string;
      task_id: string;
    }>();
  if (
    !existing ||
    ["completed", "failed", "cancelled"].includes(existing.status)
  ) {
    return;
  }

  await db
    .prepare(
      `UPDATE worker_assignments SET status = 'failed', error_json = ?1, updated_at = ?2 WHERE id = ?3`,
    )
    .bind(JSON.stringify(normalizedFailure), now, assignmentId)
    .run();

  await db
    .prepare(
      "UPDATE workflow_tasks SET status = 'failed', error = ?1, finished_at = ?2, updated_at = ?2 WHERE id = ?3",
    )
    .bind(normalizedFailure.error.message, now, existing.task_id)
    .run();
}

export async function recordAssignmentCancelled(
  db: D1Database,
  assignmentId: string,
  cancellation: { status: "cancelled"; reason: string },
): Promise<void> {
  const now = new Date().toISOString();
  const existing = await db
    .prepare(`SELECT status, task_id FROM worker_assignments WHERE id = ?1`)
    .bind(assignmentId)
    .first<{
      status: string;
      task_id: string;
    }>();
  if (
    !existing ||
    ["completed", "failed", "cancelled"].includes(existing.status)
  ) {
    return;
  }
  await db
    .prepare(
      "UPDATE workflow_tasks SET status = 'cancelled', finished_at = ?1, updated_at = ?1 WHERE id = ?2",
    )
    .bind(now, existing.task_id)
    .run();
  await db
    .prepare(
      `UPDATE worker_assignments SET status = 'cancelled', error_json = ?1, updated_at = ?2 WHERE id = ?3`,
    )
    .bind(JSON.stringify(cancellation), now, assignmentId)
    .run();
}

/**
 * Cancels a running task assignment across Cloud and Workspace.
 */
export async function cancelTaskAssignment(
  env: AssignmentDispatcherEnv,
  workspaceId: string,
  assignmentId: string,
  reason: string,
): Promise<{ cancelled: boolean }> {
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT execution_workspace_id, runtime_identity_id, run_id, task_id, status,
            attempt_id, workspace_worker_id, idempotency_key
       FROM worker_assignments
      WHERE id = ?1 AND execution_workspace_id = ?2`,
  )
    .bind(assignmentId, workspaceId)
    .first<Record<string, unknown>>();
  if (!row) return { cancelled: false };
  if (row.status === "cancelled") return { cancelled: true };
  if (["completed", "failed"].includes(String(row.status)))
    return { cancelled: false };
  const gatewayNamespace = env.CONCLAVE_WORKSPACE_GATEWAY;
  if (!gatewayNamespace) return { cancelled: false };
  try {
    const stub = gatewayNamespace.get(gatewayNamespace.idFromName(workspaceId));
    const cancelPayload: AssignmentCancelPayload = {
      assignmentId,
      reason,
      deadlineMs: Date.now() + 10_000,
    };
    const response = await stub.fetch("http://gateway/cancel-assignment", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        executionWorkspaceId: String(row.execution_workspace_id),
        workspaceRuntimeId: String(row.runtime_identity_id),
        workerId: String(row.workspace_worker_id),
        runId: String(row.run_id),
        taskId: String(row.task_id),
        attemptId: String(row.attempt_id),
        assignmentId,
        idempotencyKey: String(row.idempotency_key),
        payload: cancelPayload,
      }),
    });
    if (!response.ok) return { cancelled: false };
    const acknowledgement = (await response.json()) as { cancelled?: unknown };
    return { cancelled: acknowledgement.cancelled === true };
  } catch {
    return { cancelled: false };
  }
}
