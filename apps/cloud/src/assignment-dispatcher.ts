import {
  type AssignmentResultPayload,
  type AssignmentFailurePayload,
  type AssignmentCancelPayload,
} from "@conclave/host-protocol";
import type { GatewayEnv } from "./host-gateway.js";
import { selectProjectExecutionTarget } from "./v5-scheduler.js";
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
  readonly credentialProfileId?: string;
  readonly accountId?: string;
  readonly configuredWorkerId?: string;
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

export interface SelectedWorkerInfo {
  readonly id: string;
  readonly agentId: string;
  readonly workerCatalogId: string;
  readonly workerVersionPolicy: string;
  readonly name: string;
  readonly independenceKey: string;
  readonly concurrencyLimit: number;
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
export async function selectWorkerForTask(
  db: D1Database,
  workspaceId: string,
  task: TaskToDispatch,
  options?: {
    excludeIndependenceKeys?: readonly string[];
    explicitWorkerId?: string;
  },
): Promise<SelectedWorkerInfo | null> {
  if (options?.explicitWorkerId) {
    const row = await db
      .prepare(
        `SELECT w.id, w.agent_id, w.plugin_id, w.plugin_version_policy, w.name,
                w.independence_key, w.concurrency_limit, w.roles_json, w.capabilities_json,
                a.status as agent_status,
                (SELECT COUNT(*) FROM worker_assignments wa
                 WHERE wa.worker_id = w.id
                   AND wa.status IN ('created', 'dispatched', 'acknowledged', 'running')) AS active_assignments
         FROM workers w
         JOIN agents a ON a.id = w.agent_id
         WHERE w.workspace_id = ?1 AND w.id = ?2 AND w.enabled = 1
           AND w.status != 'disabled' AND a.status = 'online'
           AND a.revoked_at IS NULL`,
      )
      .bind(workspaceId, options.explicitWorkerId)
      .first<Record<string, unknown>>();

    if (
      !row ||
      Number(row.active_assignments || 0) >= Number(row.concurrency_limit || 1)
    ) {
      return null;
    }

    return {
      id: String(row.id),
      agentId: String(row.agent_id),
      workerCatalogId: String(row.plugin_id),
      workerVersionPolicy: String(row.plugin_version_policy || "latest"),
      name: String(row.name),
      independenceKey: String(row.independence_key),
      concurrencyLimit: Number(row.concurrency_limit || 1),
    };
  }

  const rows = await db
    .prepare(
      `SELECT w.id, w.agent_id, w.plugin_id, w.plugin_version_policy, w.name,
              w.independence_key, w.concurrency_limit, w.roles_json, w.capabilities_json,
              w.status as worker_status, a.status as agent_status,
              (SELECT COUNT(*) FROM worker_assignments wa
               WHERE wa.worker_id = w.id
                 AND wa.status IN ('created', 'dispatched', 'acknowledged', 'running')) AS active_assignments
       FROM workers w
       JOIN agents a ON a.id = w.agent_id
       WHERE w.workspace_id = ?1 AND w.enabled = 1 AND w.status != 'disabled' AND a.status = 'online'`,
    )
    .bind(workspaceId)
    .all<Record<string, unknown>>();

  const requiredRole = task.role.toLowerCase();
  const requiredCaps = (task.capabilities || []).map((c) => c.toLowerCase());
  const excludedKeys = new Set(options?.excludeIndependenceKeys || []);

  for (const row of rows.results || []) {
    const roles = (JSON.parse(String(row.roles_json || "[]")) as string[]).map(
      (r) => r.toLowerCase(),
    );
    const caps = (
      JSON.parse(String(row.capabilities_json || "[]")) as string[]
    ).map((c) => c.toLowerCase());
    const indepKey = String(row.independence_key);

    if (
      Number(row.active_assignments || 0) >= Number(row.concurrency_limit || 1)
    ) {
      continue;
    }

    if (excludedKeys.has(indepKey)) {
      continue;
    }

    const matchesRole =
      roles.includes(requiredRole) ||
      roles.includes("implementer") ||
      roles.includes("coder") ||
      roles.includes("architect");
    if (!matchesRole) {
      continue;
    }

    const hasAllCaps = requiredCaps.every((c) => caps.includes(c));
    if (!hasAllCaps) {
      continue;
    }

    return {
      id: String(row.id),
      agentId: String(row.agent_id),
      workerCatalogId: String(row.plugin_id),
      workerVersionPolicy: String(row.plugin_version_policy || "latest"),
      name: String(row.name),
      independenceKey: indepKey,
      concurrencyLimit: Number(row.concurrency_limit || 1),
    };
  }

  return null;
}

async function dispatchV5ProjectAssignment(
  env: AssignmentDispatcherEnv,
  params: DispatchAssignmentParams,
): Promise<DispatchAssignmentResult> {
  const { runId, taskId, task } = params;
  const target = await selectProjectExecutionTarget(env.CONCLAVE_DB, {
    projectId: task.projectId!,
    requesterUserId: task.requestedByUserId!,
    role: task.role,
    capabilities: task.capabilities ?? [],
    accountId: task.accountId ?? task.credentialProfileId,
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
        "No eligible Project execution resource satisfied the Workspace Grant, Worker, Account, capacity, and permission filters",
    };
  }
  const now = new Date().toISOString();
  const attemptRow = target.isWorkspaceOwnedV7Worker
    ? null
    : await env.CONCLAVE_DB.prepare(
        "SELECT COALESCE(MAX(attempt_number), 0) + 1 as next_num FROM attempts WHERE task_id = ?1",
      )
        .bind(taskId)
        .first<{ next_num: number }>();
  const attemptNumber =
    params.explicitAttemptNumber ?? attemptRow?.next_num ?? 1;
  const randomPart = crypto.randomUUID().slice(0, 8);
  const attemptId = `att-${taskId}-${attemptNumber}-${Date.now()}-${randomPart}`;
  const assignmentId = `asg-${taskId}-${attemptNumber}-${Date.now()}-${randomPart}`;
  const idempotencyKey = `idem-${assignmentId}`;
  const timeoutMs = task.timeoutMs || 15 * 60_000;
  const snapshot = {
    ...target.permissionSnapshot,
    selectionExplanation: target.selectionExplanation,
  };
  if (!target.isWorkspaceOwnedV7Worker) {
    await env.CONCLAVE_DB.prepare(
      `INSERT INTO attempts (id, task_id, worker_id, attempt_number, input_snapshot_json, status, started_at)
       VALUES (?1, ?2, ?3, ?4, ?5, 'running', ?6)`,
    )
      .bind(
        attemptId,
        taskId,
        target.workerId,
        attemptNumber,
        JSON.stringify(task.input ?? {}),
        now,
      )
      .run();
  }
  const assignmentInsert = target.isWorkspaceOwnedV7Worker
    ? `INSERT INTO worker_assignments
       (id, project_id, execution_workspace_id, workspace_project_grant_id,
        run_id, task_id, attempt_id, requested_by_user_id, runtime_identity_id,
        worker_id, workspace_worker_id, worker_version, account_id, model, config_json,
        effective_permissions_json, permission_snapshot_json, timeout_ms,
        idempotency_key, status, input_json, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
             ?15, ?16, ?17, ?18, ?19, 'created', ?20, ?21, ?21)`
    : `INSERT INTO worker_assignments
       (id, project_id, execution_workspace_id, workspace_project_grant_id,
        run_id, task_id, attempt_id, requested_by_user_id, runtime_identity_id,
        worker_id, configured_worker_id, worker_version, account_id, model, config_json,
        effective_permissions_json, permission_snapshot_json, timeout_ms,
        idempotency_key, status, input_json, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
             ?15, ?16, ?17, ?18, ?19, 'created', ?20, ?21, ?21)`;
  await env.CONCLAVE_DB.prepare(assignmentInsert)
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
      target.configuredWorkerId,
      target.workerVersion,
      target.accountId ?? null,
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
        accountId: target.accountId,
        grantId: target.workspaceProjectGrantId,
      },
    });
  }
  if (target.isWorkspaceOwnedV7Worker) {
    await env.CONCLAVE_DB.prepare(
      "UPDATE workflow_tasks SET status = 'running', updated_at = ?1 WHERE id = ?2 AND status IN ('queued', 'waiting')",
    )
      .bind(now, taskId)
      .run();
  } else {
    await env.CONCLAVE_DB.prepare(
      "UPDATE tasks SET status = 'running', updated_at = ?1 WHERE id = ?2",
    )
      .bind(now, taskId)
      .run();
  }
  const payload = {
    snapshot: {
      assignmentId,
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
      configuredWorkerId: target.configuredWorkerId,
      workerTypeId: target.workerTypeId,
      resolvedWorkerVersion: target.workerVersion,
      credentialProfileId:
        target.credentialId ?? target.accountId ?? target.configuredWorkerId,
      accountId: target.accountId,
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
  // V6-0 removes the pre-Project dispatcher. Every assignment must carry the
  // authenticated Project requester so selection, grants, and the immutable
  // target snapshot are evaluated by the v5 scheduler.
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
  return dispatchV5ProjectAssignment(env, params);
  /*
  const now = new Date().toISOString();

  // 1. Select eligible worker
  const selectedWorker = await selectWorkerForTask(
    env.CONCLAVE_DB,
    workspaceId,
    task,
    {
      explicitWorkerId: params.explicitWorkerId,
      excludeIndependenceKeys: params.excludeIndependenceKeys,
    },
  );

  if (!selectedWorker) {
    return {
      assignmentId: "",
      attemptId: "",
      workerId: "",
      agentId: "",
      workerCatalogId: "",
      status: "failed",
      accepted: false,
      error: `No eligible online worker found for role '${task.role}' with required capabilities`,
    };
  }

  // 2. Query next attempt number or use explicit
  let attemptNumber = params.explicitAttemptNumber;
  if (!attemptNumber) {
    const attemptRow = await env.CONCLAVE_DB.prepare(
      `SELECT COALESCE(MAX(attempt_number), 0) + 1 as next_num FROM attempts WHERE task_id = ?1`,
    )
      .bind(taskId)
      .first<{ next_num: number }>();
    attemptNumber = attemptRow?.next_num ?? 1;
  }

  const randomPart = crypto.randomUUID().slice(0, 8);
  const attemptId = `att-${taskId}-${attemptNumber}-${Date.now()}-${randomPart}`;
  const assignmentId = `asg-${taskId}-${attemptNumber}-${Date.now()}-${randomPart}`;
  const idempotencyKey = `idem-${assignmentId}`;
  const timeoutMs = task.timeoutMs || 15 * 60_000;

  // 3. Insert Attempt
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO attempts (id, task_id, worker_id, attempt_number, input_snapshot_json, status, started_at)
     VALUES (?1, ?2, ?3, ?4, ?5, 'running', ?6)`,
  )
    .bind(
      attemptId,
      taskId,
      selectedWorker.id,
      attemptNumber,
      JSON.stringify(task.input || {}),
      now,
    )
    .run();

  // 4. Insert WorkerAssignment
  await env.CONCLAVE_DB.prepare(
    `INSERT INTO worker_assignments (
       id, workspace_id, run_id, task_id, attempt_id, agent_id, worker_id,
       plugin_id, resolved_plugin_version, status, input_json, idempotency_key,
       timeout_ms, created_at, updated_at
     ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'dispatched', ?10, ?11, ?12, ?13, ?13)`,
  )
    .bind(
      assignmentId,
      workspaceId,
      runId,
      taskId,
      attemptId,
      selectedWorker.agentId,
      selectedWorker.id,
      selectedWorker.workerCatalogId,
      selectedWorker.workerVersionPolicy,
      JSON.stringify(task.input || {}),
      idempotencyKey,
      timeoutMs,
      now,
    )
    .run();

  // 5. Update Task status to 'running'
  await env.CONCLAVE_DB.prepare(
    `UPDATE tasks SET status = 'running', updated_at = ?1 WHERE id = ?2`,
  )
    .bind(now, taskId)
    .run();

  // 6. Deliver to the execution Workspace Gateway if configured
  const payload: AssignmentStartPayload = {
    snapshot: {
      assignmentId,
      workspaceId,
      projectId: task.projectId ?? `project-for-${taskId}`,
      runId,
      taskId,
      attemptId,
      requestedByUserId: task.requestedByUserId ?? "system",
      hostId: selectedWorker.agentId,
      workerId: selectedWorker.id,
      resolvedWorkerVersion: selectedWorker.workerVersionPolicy,
      credentialProfileId: task.credentialProfileId ?? "unresolved",
      config: task.input || {},
      sessionPolicy: "stateless",
      permissions: [],
      contextRefs: [...(task.contextArtifactIds || [])].map((artifactId) => ({
        artifactId,
      })),
      timeoutMs,
      idempotencyKey,
    },
    input: task.input || {},
  };

  const gatewayNamespace = env.CONCLAVE_WORKSPACE_GATEWAY;
  if (!gatewayNamespace) {
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
      workerId: selectedWorker.id,
      agentId: selectedWorker.agentId,
      workerCatalogId: selectedWorker.workerCatalogId,
      status: "failed",
      accepted: false,
      error,
    };
  }

  {
    try {
      const doId = gatewayNamespace.idFromName(workspaceId);
      const stub = gatewayNamespace.get(doId);
      const response = await stub.fetch("http://gateway/dispatch-assignment", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          executionWorkspaceId: workspaceId,
          workspaceRuntimeId: selectedWorker.agentId,
          workerId: selectedWorker.id,
          runId,
          taskId,
          attemptId,
          assignmentId,
          idempotencyKey,
          payload,
        }),
      });

      if (!response.ok) {
        const errorText = await response.text();
        await recordAssignmentError(env.CONCLAVE_DB, assignmentId, {
          error: {
            code: "GATEWAY_DISPATCH_FAILED",
            message: errorText || `Gateway returned HTTP ${response.status}`,
            retryable: true,
          },
          failedAt: now,
        });
        return {
          assignmentId,
          attemptId,
          workerId: selectedWorker.id,
          agentId: selectedWorker.agentId,
          workerCatalogId: selectedWorker.workerCatalogId,
          status: "failed",
          accepted: false,
          error: errorText,
        };
      }

      const ackData = (await response.json()) as {
        accepted?: boolean;
        reason?: string;
      };
      if (ackData.accepted === false) {
        await recordAssignmentError(env.CONCLAVE_DB, assignmentId, {
          error: {
            code: "ASSIGNMENT_REJECTED_BY_AGENT",
            message: ackData.reason || "Agent rejected assignment",
            retryable: true,
          },
          failedAt: now,
        });
        return {
          assignmentId,
          attemptId,
          workerId: selectedWorker.id,
          agentId: selectedWorker.agentId,
          workerCatalogId: selectedWorker.workerCatalogId,
          status: "failed",
          accepted: false,
          error: ackData.reason,
        };
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await recordAssignmentError(env.CONCLAVE_DB, assignmentId, {
        error: {
          code: "GATEWAY_RPC_ERROR",
          message: msg,
          retryable: true,
        },
        failedAt: now,
      });
      return {
        assignmentId,
        attemptId,
        workerId: selectedWorker.id,
        agentId: selectedWorker.agentId,
        workerCatalogId: selectedWorker.workerCatalogId,
        status: "failed",
        accepted: false,
        error: msg,
      };
    }
  }

  return {
    assignmentId,
    attemptId,
    workerId: selectedWorker.id,
    agentId: selectedWorker.agentId,
    workerCatalogId: selectedWorker.workerCatalogId,
    status: "dispatched",
    accepted: true,
  };
  */
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
    .prepare(
      `SELECT status, task_id, attempt_id, workspace_worker_id FROM worker_assignments WHERE id = ?1`,
    )
    .bind(assignmentId)
    .first<{
      status: string;
      task_id: string;
      attempt_id: string;
      workspace_worker_id?: string | null;
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

  // 2. Query assignment context
  if (existing && existing.workspace_worker_id) {
    await db
      .prepare(
        "UPDATE workflow_tasks SET status = 'completed', output_json = ?1, updated_at = ?2 WHERE id = ?3",
      )
      .bind(JSON.stringify(result), now, existing.task_id)
      .run();
  } else if (existing) {
    // 3. Update attempt
    await db
      .prepare(
        `UPDATE attempts SET status = 'completed', output_artifact_ids_json = ?1, finished_at = ?2 WHERE id = ?3`,
      )
      .bind(JSON.stringify(result.artifactIds || []), now, existing.attempt_id)
      .run();

    // 4. Update task
    await db
      .prepare(
        `UPDATE tasks SET status = 'completed', updated_at = ?1 WHERE id = ?2`,
      )
      .bind(now, existing.task_id)
      .run();
  }
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
    .prepare(
      `SELECT status, task_id, attempt_id, workspace_worker_id FROM worker_assignments WHERE id = ?1`,
    )
    .bind(assignmentId)
    .first<{
      status: string;
      task_id: string;
      attempt_id: string;
      workspace_worker_id?: string | null;
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

  if (existing?.workspace_worker_id) {
    await db
      .prepare(
        "UPDATE workflow_tasks SET status = 'failed', error = ?1, updated_at = ?2 WHERE id = ?3",
      )
      .bind(failure.error.message, now, existing.task_id)
      .run();
  } else if (existing) {
    await db
      .prepare(
        `UPDATE attempts SET status = 'failed', failure_class = ?1, finished_at = ?2 WHERE id = ?3`,
      )
      .bind(failure.error.code, now, existing.attempt_id)
      .run();

    await db
      .prepare(
        `UPDATE tasks SET status = 'failed', updated_at = ?1 WHERE id = ?2`,
      )
      .bind(now, existing.task_id)
      .run();
  }
}

export async function recordAssignmentCancelled(
  db: D1Database,
  assignmentId: string,
  cancellation: { status: "cancelled"; reason: string },
): Promise<void> {
  const now = new Date().toISOString();
  const existing = await db
    .prepare(
      `SELECT status, task_id, attempt_id, workspace_worker_id FROM worker_assignments WHERE id = ?1`,
    )
    .bind(assignmentId)
    .first<{
      status: string;
      task_id: string;
      attempt_id: string;
      workspace_worker_id?: string | null;
    }>();
  if (
    !existing ||
    ["completed", "failed", "cancelled"].includes(existing.status)
  ) {
    return;
  }
  if (existing.workspace_worker_id) {
    await db
      .prepare(
        "UPDATE workflow_tasks SET status = 'cancelled', updated_at = ?1 WHERE id = ?2",
      )
      .bind(now, existing.task_id)
      .run();
    return;
  }
  await db
    .prepare(
      `UPDATE worker_assignments SET status = 'cancelled', error_json = ?1, updated_at = ?2 WHERE id = ?3`,
    )
    .bind(JSON.stringify(cancellation), now, assignmentId)
    .run();
  await db
    .prepare(
      `UPDATE attempts SET status = 'cancelled', finished_at = ?1 WHERE id = ?2`,
    )
    .bind(now, existing.attempt_id)
    .run();
  await db
    .prepare(
      `UPDATE tasks SET status = 'cancelled', updated_at = ?1 WHERE id = ?2`,
    )
    .bind(now, existing.task_id)
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
    `SELECT workspace_id, run_id, task_id, attempt_id, agent_id, worker_id, idempotency_key
     FROM worker_assignments WHERE id = ?1 AND workspace_id = ?2`,
  )
    .bind(assignmentId, workspaceId)
    .first<Record<string, unknown>>();

  if (!row) {
    return { cancelled: false };
  }

  // Update D1
  await env.CONCLAVE_DB.prepare(
    `UPDATE worker_assignments SET status = 'cancelled', updated_at = ?1 WHERE id = ?2`,
  )
    .bind(now, assignmentId)
    .run();

  await env.CONCLAVE_DB.prepare(
    `UPDATE attempts SET status = 'cancelled', finished_at = ?1 WHERE id = ?2`,
  )
    .bind(now, String(row.attempt_id))
    .run();

  await env.CONCLAVE_DB.prepare(
    `UPDATE tasks SET status = 'cancelled', updated_at = ?1 WHERE id = ?2`,
  )
    .bind(now, String(row.task_id))
    .run();

  const gatewayNamespace = env.CONCLAVE_WORKSPACE_GATEWAY;
  if (gatewayNamespace) {
    try {
      const doId = gatewayNamespace.idFromName(workspaceId);
      const stub = gatewayNamespace.get(doId);
      const cancelPayload: AssignmentCancelPayload = {
        assignmentId,
        reason,
        deadlineMs: Date.now() + 5000,
      };
      await stub.fetch("http://gateway/cancel-assignment", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          executionWorkspaceId: String(row.workspace_id),
          workspaceRuntimeId: String(row.agent_id),
          workerId: String(row.worker_id),
          runId: String(row.run_id),
          taskId: String(row.task_id),
          attemptId: String(row.attempt_id),
          assignmentId,
          idempotencyKey: String(row.idempotency_key),
          payload: cancelPayload,
        }),
      });
    } catch {
      // ignore
    }
  }

  return { cancelled: true };
}
