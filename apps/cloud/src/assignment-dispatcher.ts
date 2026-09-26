import {
  type AssignmentResultPayload,
  type AssignmentFailurePayload,
  type AssignmentCancelPayload,
} from "@conclave/host-protocol";
import type { GatewayEnv } from "./host-gateway.js";
import { selectProjectExecutionTarget } from "./v7-scheduler.js";
import { recordExecutionWorkspaceAudit } from "./v5-accounting.js";

export interface TaskToDispatch {
  readonly id: string;
  readonly role: string;
  readonly objective: string;
  readonly capabilities?: readonly string[];
  readonly input?: Record<string, unknown>;
  readonly contextArtifactIds?: readonly string[];
  readonly timeoutMs?: number;
  readonly projectId?: string;
  readonly requestedByUserId?: string;
  readonly model?: string;
  readonly requiresIndependentVerification?: boolean;
  readonly workstreamId?: string;
  readonly workRequestId?: string;
  readonly checkoutId?: string;
  readonly leaseId?: string;
  readonly fencingToken?: number;
  readonly expectedRevision?: string;
  readonly executionClass?: "stateless_read" | "stateful_workstream";
  readonly repository?: {
    readonly repositoryId: string;
    readonly revision: string;
    readonly workspaceSubpath?: string;
  };
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
  readonly agentId: string;
  readonly workerCatalogId: string;
  readonly status: "dispatched" | "failed";
  readonly accepted: boolean;
  readonly error?: string;
}

export interface AssignmentDispatcherEnv extends GatewayEnv {
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
  const target = await selectProjectExecutionTarget(env.CONCLAVE_DB, {
    projectId: task.projectId!,
    requesterUserId: task.requestedByUserId!,
    role: task.role,
    capabilities: task.capabilities ?? [],
    workspaceId: params.workspaceId || undefined,
    workerId: params.explicitWorkerId,
    excludeIndependenceKeys: params.excludeIndependenceKeys,
    model: task.model,
    executionClass: task.executionClass,
    workstreamId: task.workstreamId,
    workRequestId: task.workRequestId,
    expectedRevision: task.expectedRevision,
  });
  if (!target) {
    return {
      assignmentId: "",
      attemptId: "",
      workerId: "",
      agentId: "",
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
  const snapshot = {
    ...target.permissionSnapshot,
    selectionExplanation: target.selectionExplanation,
  };
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO worker_assignments
       (id, project_id, execution_workspace_id, workspace_project_grant_id,
        run_id, task_id, attempt_id, requested_by_user_id, runtime_identity_id,
        worker_id, workspace_worker_id, worker_version,
        account_id, model, config_json, effective_permissions_json,
        permission_snapshot_json, timeout_ms, idempotency_key, status,
        input_json, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
             ?13, ?14, ?15, ?16, ?17, ?18, ?19, 'created', ?20, ?21, ?21)`,
  )
    .bind(
      assignmentId,
      target.projectId,
      target.workspaceId,
      target.workspaceProjectGrantId,
      runId,
      taskId,
      attemptId,
      task.requestedByUserId,
      target.workspaceRuntimeIdentityId,
      target.workerTypeId,
      target.workerId,
      target.workerVersion,
      null,
      target.model,
      JSON.stringify(task.input ?? {}),
      JSON.stringify(target.effectivePermissions),
      JSON.stringify(snapshot),
      timeoutMs,
      idempotencyKey,
      JSON.stringify(task.input ?? {}),
      now,
    )
    .run();
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
        projectId: target.projectId,
        workerId: target.workerId,
        grantId: target.workspaceProjectGrantId,
      },
    });
  }
  await env.CONCLAVE_DB.prepare(
    "UPDATE workflow_tasks SET status = 'running', updated_at = ?1 WHERE id = ?2 AND status IN ('queued', 'waiting')",
  )
    .bind(now, taskId)
    .run();
  const payload = {
    snapshot: {
      assignmentId,
      objective: task.objective,
      role: task.role,
      contextArtifactIds: task.contextArtifactIds ?? [],
      workstreamId: target.workstreamId ?? task.workstreamId,
      workRequestId: target.workRequestId ?? task.workRequestId,
      checkoutId: target.checkoutId ?? task.checkoutId,
      leaseId: target.leaseId ?? task.leaseId,
      fencingToken: target.fencingToken ?? task.fencingToken,
      expectedRevision: target.expectedRevision ?? task.expectedRevision,
      executionClass: target.executionClass,
      executionWorkspaceId: target.workspaceId,
      workspaceRuntimeId: target.workspaceRuntimeIdentityId,
      projectId: target.projectId,
      runId,
      taskId,
      attemptId,
      requestedByUserId: task.requestedByUserId,
      workerId: target.workerId,
      workerTypeId: target.workerTypeId,
      resolvedWorkerVersion: target.workerVersion,
      model: target.model,
      config: task.input ?? {},
      permissions: target.effectivePermissions,
      permissionSnapshot: snapshot,
      contextRefs: (task.contextArtifactIds ?? []).map((artifactId) => ({
        artifactId,
      })),
      timeoutMs,
      idempotencyKey,
    },
    input: task.input ?? {},
  };
  if (!env.CONCLAVE_WORKSPACE_GATEWAY) {
    const error =
      "Workspace Gateway is not configured; assignment was not dispatched";
    await recordAssignmentError(env.CONCLAVE_DB, assignmentId, {
      error: {
        code: "WORKSPACE_GATEWAY_NOT_CONFIGURED",
        message: error,
        retryable: true,
      },
      failedAt: now,
    });
    return {
      assignmentId,
      attemptId,
      workerId: target.workerId,
      agentId: target.workspaceRuntimeIdentityId,
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
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await recordAssignmentError(env.CONCLAVE_DB, assignmentId, {
      error: { code: "GATEWAY_DISPATCH_FAILED", message, retryable: true },
      failedAt: new Date().toISOString(),
    });
    return {
      assignmentId,
      attemptId,
      workerId: target.workerId,
      agentId: target.workspaceRuntimeIdentityId,
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
    agentId: target.workspaceRuntimeIdentityId,
    workerCatalogId: target.workerTypeId,
    status: "dispatched",
    accepted: true,
  };
}

/**
 * Creates an Attempt and WorkerAssignment in D1 and dispatches the task over the Host Gateway.
 */
export async function dispatchTaskAssignment(
  env: AssignmentDispatcherEnv,
  params: DispatchAssignmentParams,
): Promise<DispatchAssignmentResult> {
  const { task } = params;
  // Every assignment carries the authenticated Project requester so V7
  // selection, grants, and the immutable target snapshot are evaluated.
  if (!task.projectId || !task.requestedByUserId) {
    return {
      assignmentId: "",
      attemptId: "",
      workerId: "",
      agentId: "",
      workerCatalogId: "",
      status: "failed",
      accepted: false,
      error: "Project execution context is required for assignment dispatch",
    };
  }
  return dispatchWorkspaceWorkerAssignment(env, params);
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
      "UPDATE workflow_tasks SET status = 'completed', output_json = ?1, updated_at = ?2 WHERE id = ?3",
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
    .bind(JSON.stringify(failure), now, assignmentId)
    .run();

  await db
    .prepare(
      "UPDATE workflow_tasks SET status = 'failed', error = ?1, updated_at = ?2 WHERE id = ?3",
    )
    .bind(failure.error.message, now, existing.task_id)
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
      "UPDATE workflow_tasks SET status = 'cancelled', updated_at = ?1 WHERE id = ?2",
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
 * Cancels a running task assignment across Cloud and Agent.
 */
export async function cancelTaskAssignment(
  env: AssignmentDispatcherEnv,
  workspaceId: string,
  assignmentId: string,
  reason: string,
): Promise<{ cancelled: boolean }> {
  const now = new Date().toISOString();
  const row = await env.CONCLAVE_DB.prepare(
    `SELECT execution_workspace_id, runtime_identity_id, run_id, task_id,
            attempt_id, workspace_worker_id, idempotency_key
       FROM worker_assignments
      WHERE id = ?1 AND execution_workspace_id = ?2`,
  )
    .bind(assignmentId, workspaceId)
    .first<Record<string, unknown>>();
  if (!row) return { cancelled: false };
  await env.CONCLAVE_DB.prepare(
    `UPDATE worker_assignments SET status = 'cancelled', updated_at = ?1
      WHERE id = ?2 AND status IN ('created', 'dispatched', 'acknowledged', 'running')`,
  )
    .bind(now, assignmentId)
    .run();
  await env.CONCLAVE_DB.prepare(
    `UPDATE workflow_tasks SET status = 'cancelled', updated_at = ?1 WHERE id = ?2`,
  )
    .bind(now, String(row.task_id))
    .run();
  const gatewayNamespace = env.CONCLAVE_WORKSPACE_GATEWAY;
  if (gatewayNamespace) {
    try {
      const stub = gatewayNamespace.get(
        gatewayNamespace.idFromName(workspaceId),
      );
      const cancelPayload: AssignmentCancelPayload = {
        assignmentId,
        reason,
        deadlineMs: Date.now() + 5000,
      };
      await stub.fetch("http://gateway/cancel-assignment", {
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
    } catch {
      // Reconciliation on reconnect will deliver the terminal assignment state.
    }
  }
  return { cancelled: true };
}
