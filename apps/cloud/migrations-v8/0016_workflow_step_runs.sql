-- WorkflowRun timestamps are lifecycle evidence captured from Work Request transitions.
DROP TRIGGER trg_conversation_workflow_run_immutable;
ALTER TABLE conversation_workflow_runs ADD COLUMN started_at TEXT;
ALTER TABLE conversation_workflow_runs ADD COLUMN completed_at TEXT;
UPDATE conversation_workflow_runs SET
 started_at=(SELECT MIN(started_at) FROM (
   SELECT started_at FROM runs WHERE work_request_id=conversation_workflow_runs.work_request_id
   UNION ALL SELECT started_at FROM workflow_tasks WHERE work_request_id=conversation_workflow_runs.work_request_id
   UNION ALL SELECT started_at FROM conversation_turns WHERE workflow_run_id=conversation_workflow_runs.id)),
 completed_at=(SELECT CASE WHEN status IN ('completed','failed','cancelled') THEN updated_at ELSE NULL END
   FROM work_requests WHERE id=conversation_workflow_runs.work_request_id);
CREATE TRIGGER trg_conversation_workflow_run_immutable BEFORE UPDATE ON conversation_workflow_runs
WHEN OLD.id IS NOT NEW.id OR OLD.conversation_id IS NOT NEW.conversation_id
 OR OLD.user_message_id IS NOT NEW.user_message_id OR OLD.work_request_id IS NOT NEW.work_request_id
 OR OLD.workflow_id IS NOT NEW.workflow_id OR OLD.workflow_version IS NOT NEW.workflow_version OR OLD.created_at IS NOT NEW.created_at
BEGIN SELECT RAISE(ABORT, 'Workflow Run identity is immutable'); END;
CREATE TRIGGER trg_workflow_run_first_start_immutable BEFORE UPDATE OF started_at ON conversation_workflow_runs
WHEN OLD.started_at IS NOT NULL AND OLD.started_at IS NOT NEW.started_at
BEGIN SELECT RAISE(ABORT, 'Workflow Run first start is immutable'); END;
CREATE TRIGGER trg_workflow_run_request_lifecycle AFTER UPDATE OF status ON work_requests
WHEN OLD.status IS NOT NEW.status
BEGIN
 UPDATE conversation_workflow_runs SET
  started_at=CASE WHEN NEW.status='running' THEN COALESCE(started_at,NEW.updated_at) ELSE started_at END,
  completed_at=CASE WHEN NEW.status IN ('completed','failed','cancelled') THEN NEW.updated_at ELSE NULL END
 WHERE work_request_id=NEW.id;
END;
CREATE TRIGGER trg_workflow_run_initial_lifecycle AFTER INSERT ON conversation_workflow_runs
BEGIN
 UPDATE conversation_workflow_runs SET
  started_at=(SELECT CASE WHEN status='running' THEN updated_at ELSE NULL END FROM work_requests WHERE id=NEW.work_request_id),
  completed_at=(SELECT CASE WHEN status IN ('completed','failed','cancelled') THEN updated_at ELSE NULL END FROM work_requests WHERE id=NEW.work_request_id)
 WHERE id=NEW.id;
END;
-- Phase 19: logical step identity is separate from individual Worker attempts.
CREATE TABLE conversation_workflow_step_runs (
  id TEXT PRIMARY KEY,
  workflow_run_id TEXT NOT NULL REFERENCES conversation_workflow_runs(id) ON DELETE CASCADE,
  task_id TEXT NOT NULL UNIQUE REFERENCES workflow_tasks(id) ON DELETE CASCADE,
  step_id TEXT NOT NULL,
  role TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE (workflow_run_id, step_id)
);
CREATE INDEX idx_workflow_step_runs_run ON conversation_workflow_step_runs(workflow_run_id,created_at,id);
INSERT INTO conversation_workflow_step_runs(id,workflow_run_id,task_id,step_id,role,created_at)
SELECT 'step-run-' || t.id,r.id,t.id,t.step_kind,t.step_kind,t.created_at
FROM workflow_tasks t JOIN conversation_workflow_runs r ON r.work_request_id=t.work_request_id;
CREATE TRIGGER trg_workflow_step_run_scope_insert BEFORE INSERT ON conversation_workflow_step_runs
WHEN NOT EXISTS (SELECT 1 FROM workflow_tasks t JOIN conversation_workflow_runs r ON r.work_request_id=t.work_request_id
 WHERE t.id=NEW.task_id AND r.id=NEW.workflow_run_id AND t.step_kind=NEW.step_id AND t.step_kind=NEW.role)
BEGIN SELECT RAISE(ABORT, 'Workflow Step Run must belong to its scoped task and Workflow Run'); END;
CREATE TRIGGER trg_workflow_step_run_task_insert AFTER INSERT ON workflow_tasks
BEGIN
 INSERT INTO conversation_workflow_step_runs(id,workflow_run_id,task_id,step_id,role,created_at)
 SELECT 'step-run-' || NEW.id,r.id,NEW.id,NEW.step_kind,NEW.step_kind,NEW.created_at
 FROM conversation_workflow_runs r WHERE r.work_request_id=NEW.work_request_id;
END;
CREATE TRIGGER trg_workflow_step_run_run_insert AFTER INSERT ON conversation_workflow_runs
BEGIN
 INSERT INTO conversation_workflow_step_runs(id,workflow_run_id,task_id,step_id,role,created_at)
 SELECT 'step-run-' || t.id,NEW.id,t.id,t.step_kind,t.step_kind,t.created_at
 FROM workflow_tasks t WHERE t.work_request_id=NEW.work_request_id;
END;
CREATE TRIGGER trg_workflow_step_run_immutable BEFORE UPDATE ON conversation_workflow_step_runs
BEGIN SELECT RAISE(ABORT, 'Workflow Step Run identity is immutable'); END;
ALTER TABLE conversation_turns ADD COLUMN workflow_step_run_id TEXT REFERENCES conversation_workflow_step_runs(id) ON DELETE CASCADE;
UPDATE conversation_turns SET workflow_step_run_id = 'step-run-' || task_id;
CREATE INDEX idx_conversation_turns_step_run ON conversation_turns(workflow_step_run_id,created_at,id);
CREATE TRIGGER trg_conversation_turn_step_run_insert BEFORE INSERT ON conversation_turns
WHEN NEW.workflow_step_run_id IS NULL OR NOT EXISTS (SELECT 1 FROM conversation_workflow_step_runs s
 WHERE s.id=NEW.workflow_step_run_id AND s.workflow_run_id=NEW.workflow_run_id AND s.task_id=NEW.task_id)
BEGIN SELECT RAISE(ABORT, 'Worker turn must belong to its scoped Workflow Step Run'); END;
CREATE TRIGGER trg_conversation_turn_step_run_immutable BEFORE UPDATE OF workflow_step_run_id ON conversation_turns
WHEN OLD.workflow_step_run_id IS NOT NEW.workflow_step_run_id
BEGIN SELECT RAISE(ABORT, 'Worker turn Workflow Step Run is immutable'); END;
DROP TRIGGER trg_conversation_turn_assignment_insert;
CREATE TRIGGER trg_conversation_turn_assignment_insert
AFTER INSERT ON worker_assignments
BEGIN
  INSERT INTO conversation_turns (
    id, conversation_id, user_message_id, work_request_id, assignment_id, workflow_run_id, workflow_step_run_id,
    task_id, step_kind, workflow_id, workflow_version,
    worker_id, worker_type_id, worker_display_name, profile_id, profile_version,
    model_id, effort, worker_session_id, base_context_revision, status, created_at
  )
  SELECT 'turn-' || NEW.id, c.id, m.id, wr.id, NEW.id, wfr.id, wsr.id,
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
  JOIN conversation_workflow_step_runs wsr ON wsr.task_id = wt.id AND wsr.workflow_run_id = wfr.id
  WHERE wt.id = NEW.task_id;
END;

