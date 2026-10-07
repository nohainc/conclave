-- Phase 18: one stable WorkflowRun owns any number of actual Worker turns.
-- Work Request owns lifecycle/configuration; runs are scheduler execution attempts.
CREATE TABLE conversation_workflow_runs (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_message_id TEXT NOT NULL,
  work_request_id TEXT NOT NULL UNIQUE REFERENCES work_requests(id) ON DELETE CASCADE,
  workflow_id TEXT NOT NULL,
  workflow_version INTEGER NOT NULL CHECK (workflow_version > 0),
  created_at TEXT NOT NULL,
  FOREIGN KEY (user_message_id, conversation_id) REFERENCES conversation_user_messages(id, conversation_id) ON DELETE CASCADE
);
CREATE INDEX idx_conversation_workflow_runs_message ON conversation_workflow_runs(user_message_id, created_at, id);
INSERT INTO conversation_workflow_runs(id,conversation_id,user_message_id,work_request_id,workflow_id,workflow_version,created_at)
SELECT 'workflow-run-' || wr.id,m.conversation_id,m.id,wr.id,wr.workflow_id,wr.workflow_version,wr.created_at
FROM conversation_user_messages m JOIN work_requests wr ON wr.id=m.work_request_id;
CREATE TRIGGER trg_conversation_workflow_run_scope_insert BEFORE INSERT ON conversation_workflow_runs
WHEN NOT EXISTS (
 SELECT 1 FROM conversation_user_messages m JOIN work_requests wr ON wr.id=m.work_request_id
 WHERE m.id=NEW.user_message_id AND m.conversation_id=NEW.conversation_id
 AND wr.id=NEW.work_request_id AND wr.workflow_id=NEW.workflow_id AND wr.workflow_version=NEW.workflow_version)
BEGIN SELECT RAISE(ABORT, 'Workflow Run must belong to its scoped user message'); END;
CREATE TRIGGER trg_conversation_workflow_run_message_insert
AFTER INSERT ON conversation_user_messages
BEGIN
  INSERT INTO conversation_workflow_runs(id,conversation_id,user_message_id,work_request_id,workflow_id,workflow_version,created_at)
  SELECT 'workflow-run-' || wr.id,NEW.conversation_id,NEW.id,wr.id,wr.workflow_id,wr.workflow_version,wr.created_at
  FROM work_requests wr WHERE wr.id=NEW.work_request_id;
END;
CREATE TRIGGER trg_conversation_workflow_run_immutable BEFORE UPDATE ON conversation_workflow_runs
BEGIN SELECT RAISE(ABORT, 'Workflow Run identity is immutable'); END;
ALTER TABLE conversation_turns ADD COLUMN workflow_run_id TEXT REFERENCES conversation_workflow_runs(id) ON DELETE CASCADE;
UPDATE conversation_turns SET workflow_run_id = 'workflow-run-' || work_request_id;
CREATE INDEX idx_conversation_turns_workflow_run ON conversation_turns(workflow_run_id,created_at,id);
CREATE TRIGGER trg_conversation_turn_workflow_run_insert BEFORE INSERT ON conversation_turns
WHEN NEW.workflow_run_id IS NULL OR NOT EXISTS (
 SELECT 1 FROM conversation_workflow_runs r WHERE r.id=NEW.workflow_run_id
 AND r.conversation_id=NEW.conversation_id AND r.user_message_id=NEW.user_message_id
 AND r.work_request_id=NEW.work_request_id AND r.workflow_id=NEW.workflow_id AND r.workflow_version=NEW.workflow_version)
BEGIN SELECT RAISE(ABORT, 'Worker turn must belong to its scoped Workflow Run'); END;
CREATE TRIGGER trg_conversation_turn_workflow_run_immutable BEFORE UPDATE OF workflow_run_id ON conversation_turns
WHEN OLD.workflow_run_id IS NOT NEW.workflow_run_id
BEGIN SELECT RAISE(ABORT, 'Worker turn Workflow Run is immutable'); END;
DROP TRIGGER trg_conversation_turn_assignment_insert;
CREATE TRIGGER trg_conversation_turn_assignment_insert
AFTER INSERT ON worker_assignments
BEGIN
  INSERT INTO conversation_turns (
    id, conversation_id, user_message_id, work_request_id, assignment_id, workflow_run_id,
    task_id, step_kind, workflow_id, workflow_version,
    worker_id, worker_type_id, worker_display_name, profile_id, profile_version,
    model_id, effort, worker_session_id, base_context_revision, status, created_at
  )
  SELECT 'turn-' || NEW.id, c.id, m.id, wr.id, NEW.id, wfr.id,
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
  JOIN conversation_workflow_runs wfr ON wfr.work_request_id = wr.id
  WHERE wt.id = NEW.task_id;
END;

