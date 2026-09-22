/**
 * Conclave AX Architecture v2 - Cloud Multi-Agent Ensemble Dispatcher.
 *
 * Coordinates multi-agent and multi-worker execution across heterogeneous agents and machines
 * (e.g. MacBook, Linux server, Web worker) backed by Cloud D1 persistence and AgentGateway Durable Objects.
 */

import {
  executeMultiAgentEnsemble,
  type MultiAgentEnsemblePolicy,
  type MultiAgentEnsembleResult,
  type MultiAgentWorkerDescriptor,
  type MultiAgentTaskRequest,
} from "@conclave/core";
import {
  cancelTaskAssignment,
  dispatchTaskAssignment,
  type AssignmentDispatcherEnv,
  type TaskToDispatch,
} from "./assignment-dispatcher.js";

export interface EnsembleDispatchParams {
  readonly workspaceId: string;
  readonly runId: string;
  readonly taskId: string;
  readonly task: TaskToDispatch;
  readonly policy: MultiAgentEnsemblePolicy;
  readonly explicitCandidateWorkerIds?: readonly string[];
  readonly synthesizerWorkerId?: string;
  readonly selectorWorkerId?: string;
  readonly reviewerWorkerIds?: readonly string[];
  readonly candidateWorkspaces?: readonly string[];
}

export interface SelectedEnsembleWorker {
  readonly id: string;
  readonly agentId: string;
  readonly pluginId: string;
  readonly name: string;
  readonly role: string;
  readonly capabilities: readonly string[];
  readonly independenceKey: string;
}

function roleTask(
  task: TaskToDispatch,
  role: string,
  capability: string,
): TaskToDispatch {
  return { ...task, role, capabilities: [capability] };
}

function jsonStrings(value: unknown): string[] {
  if (typeof value !== "string") return [];
  try {
    const parsed: unknown = JSON.parse(value);
    return Array.isArray(parsed)
      ? parsed.filter((item): item is string => typeof item === "string")
      : [];
  } catch {
    return [];
  }
}

function matchesTask(
  row: Record<string, unknown>,
  task: TaskToDispatch,
): boolean {
  const requiredRole = task.role.toLowerCase();
  const roles = jsonStrings(row.roles_json).map((role) => role.toLowerCase());
  const capabilities = jsonStrings(row.capabilities_json).map((capability) =>
    capability.toLowerCase(),
  );
  const matchesRole =
    roles.includes(requiredRole) ||
    roles.includes("implementer") ||
    roles.includes("coder") ||
    roles.includes("architect");
  return (
    matchesRole &&
    (task.capabilities || [])
      .map((capability) => capability.toLowerCase())
      .every((capability) => capabilities.includes(capability))
  );
}

function toSelectedWorker(
  row: Record<string, unknown>,
  task: TaskToDispatch,
): SelectedEnsembleWorker {
  return {
    id: String(row.id),
    agentId: String(row.agent_id),
    pluginId: String(row.plugin_id),
    name: String(row.name),
    role: task.role,
    capabilities: jsonStrings(row.capabilities_json),
    independenceKey: String(row.independence_key),
  };
}

async function waitForAssignmentResult(
  db: D1Database,
  assignmentId: string,
  timeoutMs: number,
): Promise<
  | { status: "completed"; result: Record<string, unknown> }
  | { status: "failed"; error: string }
  | { status: "timed_out"; error: string }
> {
  const deadline = Date.now() + Math.max(1000, timeoutMs);
  while (Date.now() < deadline) {
    const row = await db
      .prepare(
        "SELECT status, output_json, error_json FROM worker_assignments WHERE id = ?1",
      )
      .bind(assignmentId)
      .first<{
        status: string;
        output_json: string | null;
        error_json: string | null;
      }>();
    if (row?.status === "completed") {
      try {
        const result = JSON.parse(row.output_json || "{}");
        if (typeof result === "object" && result !== null) {
          return {
            status: "completed",
            result: result as Record<string, unknown>,
          };
        }
      } catch {
        // Fall through as a malformed terminal result.
      }
      return { status: "failed", error: "Agent returned malformed output" };
    }
    if (row?.status === "failed" || row?.status === "cancelled") {
      return {
        status: "failed",
        error: row.error_json || `Assignment ended with status ${row.status}`,
      };
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  return { status: "timed_out", error: "Timed out waiting for Agent result" };
}

/**
 * Selects N candidate workers matching role and capabilities across online agents with distinct independence keys.
 */
export async function selectEnsembleCandidateWorkers(
  db: D1Database,
  workspaceId: string,
  task: TaskToDispatch,
  count = 2,
  explicitWorkerIds?: readonly string[],
): Promise<readonly SelectedEnsembleWorker[]> {
  if (explicitWorkerIds && explicitWorkerIds.length > 0) {
    const placeholders = explicitWorkerIds.map((_, i) => `?${i + 2}`).join(",");
    const rows = await db
      .prepare(
        `SELECT w.id, w.agent_id, w.plugin_id, w.name, w.independence_key,
                w.roles_json, w.capabilities_json, w.concurrency_limit,
                (SELECT COUNT(*) FROM worker_assignments wa
                 WHERE wa.worker_id = w.id
                   AND wa.status IN ('created', 'dispatched', 'acknowledged', 'running')) AS active_assignments,
                a.status as agent_status
         FROM workers w
         JOIN agents a ON a.id = w.agent_id
         WHERE w.workspace_id = ?1 AND w.id IN (${placeholders}) AND w.enabled = 1
           AND w.status != 'disabled' AND a.status = 'online'
           AND a.revoked_at IS NULL`,
      )
      .bind(workspaceId, ...explicitWorkerIds)
      .all<Record<string, unknown>>();

    const selected: SelectedEnsembleWorker[] = [];
    const usedIndependenceKeys = new Set<string>();
    for (const row of rows.results || []) {
      if (
        !matchesTask(row, task) ||
        Number(row.active_assignments || 0) >=
          Number(row.concurrency_limit || 1) ||
        usedIndependenceKeys.has(String(row.independence_key))
      ) {
        continue;
      }
      usedIndependenceKeys.add(String(row.independence_key));
      selected.push(toSelectedWorker(row, task));
      if (selected.length >= count) break;
    }
    return selected;
  }

  const rows = await db
    .prepare(
      `SELECT w.id, w.agent_id, w.plugin_id, w.name, w.independence_key,
              w.roles_json, w.capabilities_json, w.concurrency_limit,
              (SELECT COUNT(*) FROM worker_assignments wa
               WHERE wa.worker_id = w.id
                 AND wa.status IN ('created', 'dispatched', 'acknowledged', 'running')) AS active_assignments,
              w.status as worker_status, a.status as agent_status
       FROM workers w
       JOIN agents a ON a.id = w.agent_id
       WHERE w.workspace_id = ?1 AND w.enabled = 1 AND w.status != 'disabled'
         AND a.status = 'online' AND a.revoked_at IS NULL`,
    )
    .bind(workspaceId)
    .all<Record<string, unknown>>();

  const selected: SelectedEnsembleWorker[] = [];
  const usedIndependenceKeys = new Set<string>();

  for (const row of rows.results || []) {
    if (selected.length >= count) break;

    const indepKey = String(row.independence_key);

    if (
      !matchesTask(row, task) ||
      Number(row.active_assignments || 0) >=
        Number(row.concurrency_limit || 1) ||
      usedIndependenceKeys.has(indepKey)
    ) {
      continue;
    }

    usedIndependenceKeys.add(indepKey);
    selected.push(toSelectedWorker(row, task));
  }

  return selected;
}

/**
 * Creates a worker descriptor bridge from a SelectedEnsembleWorker.
 */
function createWorkerDescriptor(
  env: AssignmentDispatcherEnv,
  workspaceId: string,
  runId: string,
  taskId: string,
  worker: SelectedEnsembleWorker,
  attemptNumber?: number,
): MultiAgentWorkerDescriptor {
  return {
    workerId: worker.id,
    agentId: worker.agentId,
    pluginId: worker.pluginId,
    name: worker.name,
    role: worker.role,
    capabilities: worker.capabilities,
    independenceKey: worker.independenceKey,
    execute: async (taskReq: MultiAgentTaskRequest) => {
      const dispatchRes = await dispatchTaskAssignment(env, {
        workspaceId,
        runId,
        taskId,
        task: {
          id: taskReq.taskId,
          role: taskReq.role,
          objective: taskReq.objective,
          capabilities: taskReq.requiredCapabilities,
          input: taskReq.input,
          contextArtifactIds: taskReq.contextArtifactIds,
          timeoutMs: taskReq.timeoutMs,
        },
        explicitWorkerId: worker.id,
        explicitAttemptNumber: attemptNumber,
      });

      if (dispatchRes.status === "failed") {
        return {
          status: "failed",
          output: null,
          error: {
            code: "DISPATCH_REJECTED",
            message: dispatchRes.error || "Agent rejected assignment",
            retryable: true,
          },
        };
      }

      const completed = await waitForAssignmentResult(
        env.CONCLAVE_DB,
        dispatchRes.assignmentId,
        taskReq.timeoutMs ?? 15 * 60_000,
      );
      if (completed.status !== "completed") {
        if (completed.status === "timed_out") {
          await cancelTaskAssignment(
            env,
            dispatchRes.assignmentId,
            "Ensemble worker result timed out",
          );
        }
        return {
          status: completed.status,
          output: null,
          error: {
            code:
              completed.status === "timed_out"
                ? "ASSIGNMENT_TIMEOUT"
                : "ASSIGNMENT_FAILED",
            message: completed.error,
            retryable: completed.status === "timed_out",
          },
        };
      }
      const result = completed.result;
      const output =
        typeof result.output === "object" && result.output !== null
          ? (result.output as Record<string, unknown>)
          : { summary: String(result.summary ?? "Agent assignment completed") };
      return {
        status: "succeeded",
        output: {
          ...output,
          assignmentId: dispatchRes.assignmentId,
          attemptId: dispatchRes.attemptId,
        },
        rawOutput: JSON.stringify(result),
        artifactIds: Array.isArray(result.artifactIds)
          ? result.artifactIds.filter(
              (value): value is string => typeof value === "string",
            )
          : [],
        findings: Array.isArray(result.findings) ? result.findings : [],
      };
    },
  };
}

/**
 * Dispatches and coordinates a multi-agent ensemble across disparate machines.
 */
export async function dispatchEnsembleTaskAssignment(
  env: AssignmentDispatcherEnv,
  params: EnsembleDispatchParams,
): Promise<MultiAgentEnsembleResult> {
  const { workspaceId, runId, taskId, task, policy } = params;

  const targetCount =
    policy.mode === "single"
      ? 1
      : policy.maxParallel && policy.maxParallel > 1
        ? policy.maxParallel
        : 3;

  const selectedWorkers = await selectEnsembleCandidateWorkers(
    env.CONCLAVE_DB,
    workspaceId,
    task,
    targetCount,
    params.explicitCandidateWorkerIds,
  );

  if (selectedWorkers.length === 0) {
    throw new Error(
      `No eligible online candidate workers found for task '${task.id}'`,
    );
  }

  const candidateDescriptors = selectedWorkers.map((w, index) =>
    createWorkerDescriptor(env, workspaceId, runId, taskId, w, index + 1),
  );

  let synthesizerDescriptor: MultiAgentWorkerDescriptor | undefined;
  if (params.synthesizerWorkerId) {
    const synthWorker = (
      await selectEnsembleCandidateWorkers(
        env.CONCLAVE_DB,
        workspaceId,
        roleTask(task, "synthesizer", "synthesis"),
        1,
        [params.synthesizerWorkerId],
      )
    )[0];
    if (synthWorker) {
      synthesizerDescriptor = createWorkerDescriptor(
        env,
        workspaceId,
        runId,
        taskId,
        synthWorker,
        selectedWorkers.length + 1,
      );
    }
  }

  let selectorDescriptor: MultiAgentWorkerDescriptor | undefined;
  if (params.selectorWorkerId) {
    const selWorker = (
      await selectEnsembleCandidateWorkers(
        env.CONCLAVE_DB,
        workspaceId,
        roleTask(task, "evaluator", "evaluation"),
        1,
        [params.selectorWorkerId],
      )
    )[0];
    if (selWorker) {
      selectorDescriptor = createWorkerDescriptor(
        env,
        workspaceId,
        runId,
        taskId,
        selWorker,
        selectedWorkers.length + 2,
      );
    }
  }

  let reviewerDescriptors: MultiAgentWorkerDescriptor[] | undefined;
  if (params.reviewerWorkerIds && params.reviewerWorkerIds.length > 0) {
    const revWorkers = await selectEnsembleCandidateWorkers(
      env.CONCLAVE_DB,
      workspaceId,
      roleTask(task, "reviewer", "code_review"),
      params.reviewerWorkerIds.length,
      params.reviewerWorkerIds,
    );
    reviewerDescriptors = revWorkers.map((w, idx) =>
      createWorkerDescriptor(
        env,
        workspaceId,
        runId,
        taskId,
        w,
        selectedWorkers.length + 10 + idx,
      ),
    );
  }

  const ensembleResult = await executeMultiAgentEnsemble({
    policy,
    task: {
      taskId,
      role: task.role,
      objective: task.objective,
      requiredCapabilities: task.capabilities,
      input: task.input,
      contextArtifactIds: task.contextArtifactIds,
      timeoutMs: task.timeoutMs,
      goalId: runId,
      runId,
    },
    candidates: candidateDescriptors,
    synthesizer: synthesizerDescriptor,
    selector: selectorDescriptor,
    reviewers: reviewerDescriptors,
    candidateWorkspaces: params.candidateWorkspaces,
  });

  return ensembleResult;
}
