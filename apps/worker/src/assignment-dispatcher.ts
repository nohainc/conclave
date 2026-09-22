import {
  type AssignmentStartPayload,
  type AssignmentResultPayload,
  type AssignmentFailurePayload,
  type AssignmentCancelPayload,
} from "@conclave/agent-protocol";
import type { GatewayEnv } from "./host-gateway.js";

export interface TaskToDispatch {
  readonly id: string;
  readonly role: string;
  readonly objective: string;
  readonly capabilities?: readonly string[];
  readonly input?: Record<string, unknown>;
  readonly contextArtifactIds?: readonly string[];
  readonly timeoutMs?: number;
  readonly requiresIndependentVerification?: boolean;
  readonly repository?: {
    readonly repositoryId: string;
    readonly revision: string;
    readonly workspaceSubpath?: string;
  };
}

export interface SelectedWorkerInfo {
  readonly id: string;
  readonly agentId: string;
  readonly pluginId: string;
  readonly pluginVersionPolicy: string;
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
  readonly pluginId: string;
  readonly status: "dispatched" | "failed";
  readonly accepted: boolean;
  readonly error?: string;
}

export interface AssignmentDispatcherEnv extends GatewayEnv {
  readonly CONCLAVE_HOST_GATEWAY?: DurableObjectNamespace;
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
      pluginId: String(row.plugin_id),
      pluginVersionPolicy: String(row.plugin_version_policy || "latest"),
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
      pluginId: String(row.plugin_id),
      pluginVersionPolicy: String(row.plugin_version_policy || "latest"),
      name: String(row.name),
      independenceKey: indepKey,
      concurrencyLimit: Number(row.concurrency_limit || 1),
    };
  }

  return null;
}

/**
 * Creates an Attempt and WorkerAssignment in D1 and dispatches the task over the Host Gateway.
 */
export async function dispatchTaskAssignment(
  env: AssignmentDispatcherEnv,
  params: DispatchAssignmentParams,
): Promise<DispatchAssignmentResult> {
  const { workspaceId, runId, taskId, task } = params;
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
      pluginId: "",
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
      selectedWorker.pluginId,
      selectedWorker.pluginVersionPolicy,
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

  // 6. Deliver to HostGateway Durable Object if namespace is available
  const payload: AssignmentStartPayload = {
    pluginId: selectedWorker.pluginId,
    resolvedPluginVersion: selectedWorker.pluginVersionPolicy,
    role: task.role,
    objective: task.objective,
    input: task.input || {},
    contextArtifactIds: [...(task.contextArtifactIds || [])],
    timeoutMs,
    ...(task.repository ? { repository: task.repository } : {}),
  };

  const gatewayNamespace = env.CONCLAVE_HOST_GATEWAY;
  if (!gatewayNamespace) {
    const error =
      "Host Gateway is not configured; assignment was not dispatched";
    await recordAssignmentError(env.CONCLAVE_DB, assignmentId, {
      status: "failed",
      error: {
        code: "HOST_GATEWAY_NOT_CONFIGURED",
        message: error,
        retryable: true,
      },
    });
    return {
      assignmentId,
      attemptId,
      workerId: selectedWorker.id,
      agentId: selectedWorker.agentId,
      pluginId: selectedWorker.pluginId,
      status: "failed",
      accepted: false,
      error,
    };
  }

  {
    try {
      const doId = gatewayNamespace.idFromName(selectedWorker.agentId);
      const stub = gatewayNamespace.get(doId);
      const response = await stub.fetch("http://gateway/dispatch-assignment", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          workspaceId,
          agentId: selectedWorker.agentId,
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
          status: "failed",
          error: {
            code: "GATEWAY_DISPATCH_FAILED",
            message: errorText || `Gateway returned HTTP ${response.status}`,
            retryable: true,
          },
        });
        return {
          assignmentId,
          attemptId,
          workerId: selectedWorker.id,
          agentId: selectedWorker.agentId,
          pluginId: selectedWorker.pluginId,
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
          status: "failed",
          error: {
            code: "ASSIGNMENT_REJECTED_BY_AGENT",
            message: ackData.reason || "Agent rejected assignment",
            retryable: true,
          },
        });
        return {
          assignmentId,
          attemptId,
          workerId: selectedWorker.id,
          agentId: selectedWorker.agentId,
          pluginId: selectedWorker.pluginId,
          status: "failed",
          accepted: false,
          error: ackData.reason,
        };
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      await recordAssignmentError(env.CONCLAVE_DB, assignmentId, {
        status: "failed",
        error: {
          code: "GATEWAY_RPC_ERROR",
          message: msg,
          retryable: true,
        },
      });
      return {
        assignmentId,
        attemptId,
        workerId: selectedWorker.id,
        agentId: selectedWorker.agentId,
        pluginId: selectedWorker.pluginId,
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
    pluginId: selectedWorker.pluginId,
    status: "dispatched",
    accepted: true,
  };
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
      `SELECT status, task_id, attempt_id FROM worker_assignments WHERE id = ?1`,
    )
    .bind(assignmentId)
    .first<{ status: string; task_id: string; attempt_id: string }>();
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
  if (existing) {
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
      `SELECT status, task_id, attempt_id FROM worker_assignments WHERE id = ?1`,
    )
    .bind(assignmentId)
    .first<{ status: string; task_id: string; attempt_id: string }>();
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

  if (existing) {
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
      `SELECT status, task_id, attempt_id FROM worker_assignments WHERE id = ?1`,
    )
    .bind(assignmentId)
    .first<{ status: string; task_id: string; attempt_id: string }>();
  if (
    !existing ||
    ["completed", "failed", "cancelled"].includes(existing.status)
  ) {
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

  const gatewayNamespace = env.CONCLAVE_HOST_GATEWAY;
  if (gatewayNamespace) {
    try {
      const doId = gatewayNamespace.idFromName(String(row.agent_id));
      const stub = gatewayNamespace.get(doId);
      const cancelPayload: AssignmentCancelPayload = {
        reason,
        gracePeriodMs: 5000,
      };
      await stub.fetch("http://gateway/cancel-assignment", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          workspaceId: String(row.workspace_id),
          agentId: String(row.agent_id),
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
