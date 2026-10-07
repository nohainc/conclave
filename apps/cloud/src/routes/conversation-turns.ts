import type { ConversationTurn } from "@conclave/core";

/** Call only after authorizing the enclosing Workstream/request collection. */
export async function loadConversationTurns(
  db: D1Database,
  workRequestIds: readonly string[],
): Promise<Map<string, ConversationTurn[]>> {
  const result = new Map<string, ConversationTurn[]>();
  if (!workRequestIds.length) return result;
  const rows = await db
    .prepare(
      `SELECT ct.id, ct.workflow_run_id AS workflowRunId, ct.workflow_step_run_id AS workflowStepRunId, wa.run_id AS runtimeRunId, ct.conversation_id AS conversationId,
    ct.user_message_id AS userMessageId, ct.work_request_id AS workRequestId,
    ct.assignment_id AS assignmentId, ct.task_id AS taskId, ct.step_kind AS stepKind,
    ct.workflow_id AS workflowId, ct.workflow_version AS workflowVersion,
    ct.worker_id AS workerId, ct.worker_type_id AS workerTypeId,
    ct.worker_display_name AS workerDisplayName, ct.profile_id AS profileId,
    ct.profile_version AS profileVersion, ct.model_id AS modelId, ct.effort,
    ct.worker_session_id AS workerSessionId, ct.base_context_revision AS baseContextRevision,
    ct.status, ct.started_at AS startedAt, ct.completed_at AS completedAt,
    substr(COALESCE(h.text, ct.result_text), 1, 24000) AS resultText, ct.created_at AS createdAt
    FROM conversation_turns ct JOIN worker_assignments wa ON wa.id = ct.assignment_id LEFT JOIN conversation_history_entries h ON h.turn_id = ct.id AND h.kind = 'worker_response' WHERE ct.work_request_id IN (${workRequestIds.map(() => "?").join(",")})
    ORDER BY ct.created_at, ct.rowid`,
    )
    .bind(...workRequestIds)
    .all<ConversationTurn>();
  for (const turn of rows.results ?? []) {
    const turns = result.get(turn.workRequestId) ?? [];
    turns.push(turn);
    result.set(turn.workRequestId, turns);
  }
  return result;
}

/** Prefer immutable invocation evidence over a task's mutable retry projection. */
export function withConversationTurn<T extends { assignmentId: string | null }>(
  step: T,
  turns: readonly ConversationTurn[],
) {
  const turn = turns.find((value) => value.assignmentId === step.assignmentId);
  if (!turn) return step;
  const start = turn.startedAt ? Date.parse(turn.startedAt) : NaN;
  const end = turn.completedAt ? Date.parse(turn.completedAt) : Date.now();
  return {
    ...step,
    status: turn.status,
    workerId: turn.workerId,
    workerTypeId: turn.workerTypeId,
    workerDisplayName: turn.workerDisplayName,
    profileDefinitionId: turn.profileId,
    profileReleaseVersion: turn.profileVersion,
    model: turn.modelId,
    reasoningEffort: turn.effort,
    startedAt: turn.startedAt,
    completedAt: turn.completedAt,
    elapsedMs: Number.isFinite(start) ? Math.max(0, end - start) : null,
    resultText: turn.resultText,
    finalText: turn.resultText,
  };
}
