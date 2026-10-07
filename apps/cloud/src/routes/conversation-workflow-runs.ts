import { loadConversationWorkflowStepRuns } from "./conversation-workflow-step-runs.js";
import type { WorkflowRun } from "@conclave/core";

/** Call after authorizing the enclosing request collection. Lifecycle has one owner: Work Request. */
export async function loadConversationWorkflowRuns(
  db: D1Database,
  workRequestIds: readonly string[],
): Promise<Map<string, WorkflowRun>> {
  if (!workRequestIds.length) return new Map();
  const rows = await db
    .prepare(
      `SELECT wfr.id, wfr.conversation_id AS conversationId,
    wfr.user_message_id AS userMessageId, wfr.user_message_id AS triggerMessageId, wfr.work_request_id AS workRequestId,
    wfr.workflow_id AS workflowId, wfr.workflow_version AS workflowVersion,
    wr.status, wfr.created_at AS createdAt, wr.updated_at AS updatedAt,
    wfr.started_at AS startedAt, wfr.completed_at AS completedAt,
    (SELECT json_group_array(id) FROM (SELECT id FROM runs WHERE work_request_id=wfr.work_request_id ORDER BY created_at,id)) AS runtimeRunIdsJson,
    (SELECT json_group_array(id) FROM (SELECT id FROM conversation_turns WHERE workflow_run_id=wfr.id ORDER BY created_at,rowid)) AS workerTurnIdsJson
    FROM conversation_workflow_runs wfr JOIN work_requests wr ON wr.id=wfr.work_request_id
    WHERE wfr.work_request_id IN (${workRequestIds.map(() => "?").join(",")})`,
    )
    .bind(...workRequestIds)
    .all<
      Omit<
        WorkflowRun,
        "schemaVersion" | "runtimeRunIds" | "workerTurnIds" | "stepRuns"
      > & {
        runtimeRunIdsJson: string;
        workerTurnIdsJson: string;
      }
    >();
  const steps = await loadConversationWorkflowStepRuns(db, workRequestIds);
  return new Map(
    (rows.results ?? []).map(
      ({ runtimeRunIdsJson, workerTurnIdsJson, ...row }) => [
        row.workRequestId,
        {
          ...row,
          schemaVersion: 1,
          stepRuns: steps.get(row.id) ?? [],
          runtimeRunIds: JSON.parse(runtimeRunIdsJson) as string[],
          workerTurnIds: JSON.parse(workerTurnIdsJson) as string[],
        },
      ],
    ),
  );
}
