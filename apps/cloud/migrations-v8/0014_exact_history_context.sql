-- Phase 15: exact-history context versions follow accepted requests.
UPDATE conversations SET context_revision = conversation_revision;
DROP TRIGGER trg_conversation_turn_assignment_insert;
CREATE TRIGGER trg_conversation_turn_assignment_insert
AFTER INSERT ON worker_assignments
BEGIN
  INSERT INTO conversation_turns (
    id, conversation_id, user_message_id, work_request_id, assignment_id,
    task_id, step_kind, workflow_id, workflow_version,
    worker_id, worker_type_id, worker_display_name, profile_id, profile_version,
    model_id, effort, worker_session_id, base_context_revision, status, created_at
  )
  SELECT 'turn-' || NEW.id, c.id, m.id, wr.id, NEW.id,
    wt.id, wt.step_kind, wr.workflow_id, wr.workflow_version,
    NEW.workspace_worker_id, NEW.worker_type_id,
    COALESCE(json_extract(NEW.permission_snapshot_json, '$.workerDisplayName'), NEW.worker_type_id),
    json_extract(NEW.permission_snapshot_json, '$.profileDefinitionId'),
    json_extract(NEW.permission_snapshot_json, '$.profileReleaseVersion'),
    NEW.model, json_extract(NEW.permission_snapshot_json, '$.reasoningEffort'),
    CASE WHEN NEW.session_policy = 'durable_session' THEN json_extract(NEW.permission_snapshot_json, '$.workerSessionId') ELSE NULL END,
    COALESCE(json_extract(NEW.permission_snapshot_json, '$.baseContextRevision'), cr.conversation_revision - 1), 'queued', NEW.created_at
  FROM workflow_tasks wt
  JOIN work_requests wr ON wr.id = wt.work_request_id
  JOIN conversation_work_requests cr ON cr.work_request_id = wr.id
  JOIN conversations c ON c.id = cr.conversation_id
  JOIN conversation_user_messages m ON m.work_request_id = wr.id
  WHERE wt.id = NEW.task_id;
END;

