-- Phase 4: immutable attribution per actual worker invocation, including retries.
CREATE TABLE conversation_user_messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  work_request_id TEXT NOT NULL UNIQUE REFERENCES work_requests(id) ON DELETE CASCADE,
  author_user_id TEXT NOT NULL,
  text TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE (id, conversation_id)
);

-- Existing associated requests already have authoritative immutable user text.
INSERT INTO conversation_user_messages(id, conversation_id, work_request_id, author_user_id, text, created_at)
SELECT 'message-user-' || wr.id, cr.conversation_id, wr.id, wr.requested_by_user_id,
  COALESCE(json_extract(wr.input_json, '$.originalRequest'), json_extract(wr.input_json, '$.request'), ''), wr.created_at
FROM conversation_work_requests cr JOIN work_requests wr ON wr.id = cr.work_request_id;

CREATE TABLE conversation_turns (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_message_id TEXT NOT NULL,
  work_request_id TEXT NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  assignment_id TEXT NOT NULL UNIQUE REFERENCES worker_assignments(id) ON DELETE CASCADE,
  task_id TEXT NOT NULL,
  step_kind TEXT NOT NULL,
  workflow_id TEXT NOT NULL,
  workflow_version INTEGER NOT NULL CHECK (workflow_version > 0),
  worker_id TEXT NOT NULL,
  worker_type_id TEXT NOT NULL,
  worker_display_name TEXT NOT NULL,
  profile_id TEXT NOT NULL,
  profile_version INTEGER NOT NULL CHECK (profile_version > 0),
  model_id TEXT,
  effort TEXT,
  worker_session_id TEXT,
  base_context_revision INTEGER NOT NULL CHECK (base_context_revision >= 0),
  status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'completed', 'failed', 'cancelled')),
  started_at TEXT,
  completed_at TEXT,
  result_text TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY (user_message_id, conversation_id) REFERENCES conversation_user_messages(id, conversation_id) ON DELETE CASCADE,
  CHECK ((status IN ('completed', 'failed', 'cancelled')) = (completed_at IS NOT NULL))
);
CREATE INDEX idx_conversation_turns_request ON conversation_turns(work_request_id, created_at, id);
CREATE INDEX idx_conversation_turns_history ON conversation_turns(conversation_id, created_at, id);

CREATE TRIGGER trg_conversation_user_message_insert
AFTER INSERT ON conversation_work_requests
BEGIN
  INSERT INTO conversation_user_messages(id, conversation_id, work_request_id, author_user_id, text, created_at)
  SELECT 'message-user-' || wr.id, NEW.conversation_id, wr.id, wr.requested_by_user_id,
    COALESCE(json_extract(wr.input_json, '$.originalRequest'), json_extract(wr.input_json, '$.request'), ''), wr.created_at
  FROM work_requests wr WHERE wr.id = NEW.work_request_id;
END;

CREATE TRIGGER trg_conversation_user_message_immutable
BEFORE UPDATE ON conversation_user_messages
BEGIN
  SELECT RAISE(ABORT, 'Conversation user messages are immutable');
END;

-- Creation and attribution are atomic with assignment creation. No inventory is
-- read for mutable execution configuration; signed selection evidence owns it.
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
    c.context_revision, 'queued', NEW.created_at
  FROM workflow_tasks wt
  JOIN work_requests wr ON wr.id = wt.work_request_id
  JOIN conversation_work_requests cr ON cr.work_request_id = wr.id
  JOIN conversations c ON c.id = cr.conversation_id
  JOIN conversation_user_messages m ON m.work_request_id = wr.id
  WHERE wt.id = NEW.task_id;
END;

CREATE TRIGGER trg_conversation_turn_identity_immutable
BEFORE UPDATE ON conversation_turns
WHEN OLD.id IS NOT NEW.id OR OLD.conversation_id IS NOT NEW.conversation_id
  OR OLD.user_message_id IS NOT NEW.user_message_id OR OLD.work_request_id IS NOT NEW.work_request_id
  OR OLD.assignment_id IS NOT NEW.assignment_id OR OLD.task_id IS NOT NEW.task_id OR OLD.step_kind IS NOT NEW.step_kind
  OR OLD.workflow_id IS NOT NEW.workflow_id OR OLD.workflow_version IS NOT NEW.workflow_version
  OR OLD.worker_id IS NOT NEW.worker_id OR OLD.worker_type_id IS NOT NEW.worker_type_id
  OR OLD.worker_display_name IS NOT NEW.worker_display_name
  OR OLD.profile_id IS NOT NEW.profile_id OR OLD.profile_version IS NOT NEW.profile_version
  OR OLD.model_id IS NOT NEW.model_id OR OLD.effort IS NOT NEW.effort
  OR OLD.worker_session_id IS NOT NEW.worker_session_id OR OLD.base_context_revision IS NOT NEW.base_context_revision
  OR OLD.created_at IS NOT NEW.created_at
BEGIN
  SELECT RAISE(ABORT, 'Conversation turn execution attribution is immutable');
END;

CREATE TRIGGER trg_conversation_turn_lifecycle_guard
BEFORE UPDATE ON conversation_turns
WHEN (OLD.status IN ('completed', 'failed', 'cancelled') AND
  (OLD.status IS NOT NEW.status OR OLD.started_at IS NOT NEW.started_at
   OR OLD.completed_at IS NOT NEW.completed_at OR OLD.result_text IS NOT NEW.result_text))
 OR (OLD.status = 'running' AND NEW.status = 'queued')
 OR (OLD.started_at IS NOT NULL AND OLD.started_at IS NOT NEW.started_at)
BEGIN
  SELECT RAISE(ABORT, 'Conversation turn lifecycle cannot regress or rewrite terminal evidence');
END;

CREATE TRIGGER trg_conversation_turn_assignment_status
AFTER UPDATE OF status ON worker_assignments
WHEN OLD.status IS NOT NEW.status
BEGIN
  UPDATE conversation_turns SET
    status = CASE WHEN NEW.status IN ('completed', 'failed', 'cancelled') THEN NEW.status
      WHEN NEW.status IN ('acknowledged', 'running') THEN 'running' ELSE status END,
    started_at = CASE WHEN NEW.status IN ('acknowledged', 'running') THEN COALESCE(started_at, NEW.updated_at) ELSE started_at END,
    completed_at = CASE WHEN NEW.status IN ('completed', 'failed', 'cancelled') THEN NEW.updated_at ELSE completed_at END,
    result_text = CASE WHEN NEW.status = 'completed' THEN json_extract(NEW.output_json, '$.output.text') ELSE result_text END
  WHERE assignment_id = NEW.id;
END;
