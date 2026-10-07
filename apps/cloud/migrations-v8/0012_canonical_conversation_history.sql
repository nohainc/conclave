-- Phase 5: Conclave-owned canonical history. Provider sessions are local execution state.
CREATE TABLE conversation_history_entries (
  id TEXT PRIMARY KEY DEFAULT ('history-' || lower(hex(randomblob(16)))),
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sequence INTEGER NOT NULL CHECK (typeof(sequence) = 'integer' AND sequence > 0),
  schema_version INTEGER NOT NULL DEFAULT 1 CHECK (schema_version = 1),
  kind TEXT NOT NULL CHECK (kind IN ('user_message', 'worker_response', 'workflow_event', 'execution_event', 'artifact_event', 'context_event')),
  event_type TEXT NOT NULL,
  actor_type TEXT NOT NULL CHECK (actor_type IN ('user', 'worker', 'conclave')),
  actor_id TEXT,
  -- Snapshot references intentionally survive deletion of source execution rows.
  work_request_id TEXT,
  turn_id TEXT,
  artifact_id TEXT,
  source_id TEXT NOT NULL,
  text TEXT,
  metadata_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(metadata_json) AND json_type(metadata_json) = 'object'),
  deduplication_key TEXT,
  occurred_at TEXT NOT NULL,
  recorded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  UNIQUE (conversation_id, sequence),
  UNIQUE (conversation_id, deduplication_key),
  CHECK ((kind IN ('user_message', 'worker_response')) = (text IS NOT NULL)),
  CHECK (kind != 'worker_response' OR turn_id IS NOT NULL),
  CHECK (kind != 'artifact_event' OR artifact_id IS NOT NULL)
);
CREATE INDEX idx_conversation_history_request ON conversation_history_entries(work_request_id, sequence);
CREATE INDEX idx_conversation_history_turn ON conversation_history_entries(turn_id, kind);

CREATE TRIGGER trg_conversation_history_immutable
BEFORE UPDATE ON conversation_history_entries
BEGIN
  SELECT RAISE(ABORT, 'Canonical Conversation history is append-only');
END;
CREATE TRIGGER trg_conversation_history_no_delete
BEFORE DELETE ON conversation_history_entries
WHEN EXISTS (SELECT 1 FROM conversations WHERE id = OLD.conversation_id)
BEGIN
  SELECT RAISE(ABORT, 'Canonical Conversation history cannot be deleted independently');
END;

CREATE TRIGGER trg_history_user_message
AFTER INSERT ON conversation_user_messages
BEGIN
  INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.conversation_id), 0) + 1,
    'user_message',
    'message.user_created',
    'user',
    NEW.author_user_id,
    NEW.work_request_id,
    NULL,
    NULL,
    NEW.id,
    NEW.text,
    json_object('userMessageId', NEW.id),
    'user:' || NEW.id,
    NEW.created_at
  ;
END;

CREATE TRIGGER trg_history_request_accepted
AFTER INSERT ON conversation_work_requests
BEGIN
  INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.conversation_id), 0) + 1,
    'workflow_event',
    'workflow.request_accepted',
    'conclave',
    NULL,
    NEW.work_request_id,
    NULL,
    NULL,
    NEW.work_request_id,
    NULL,
    json_object('workflowId', wr.workflow_id, 'workflowVersion', wr.workflow_version, 'status', wr.status, 'conversationRevision', NEW.conversation_revision),
    NULL,
    wr.created_at
  FROM work_requests wr WHERE wr.id = NEW.work_request_id;
END;

CREATE TRIGGER trg_history_request_status
AFTER UPDATE OF status ON work_requests
WHEN OLD.status IS NOT NEW.status
BEGIN
  INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event',
    'workflow.request_status_changed',
    'conclave',
    NULL,
    NEW.id,
    NULL,
    NULL,
    NEW.id,
    NULL,
    json_object('from', OLD.status, 'to', NEW.status, 'workflowId', NEW.workflow_id, 'workflowVersion', NEW.workflow_version),
    NULL,
    NEW.updated_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.id;
END;

CREATE TRIGGER trg_history_run_created
AFTER INSERT ON runs
BEGIN
  INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event',
    'workflow.run_created',
    'conclave',
    NULL,
    NEW.work_request_id,
    NULL,
    NULL,
    NEW.id,
    NULL,
    json_object('status', NEW.status),
    NULL,
    NEW.created_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
END;

CREATE TRIGGER trg_history_run_status
AFTER UPDATE OF status ON runs
WHEN OLD.status IS NOT NEW.status
BEGIN
  INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event',
    'workflow.run_status_changed',
    'conclave',
    NULL,
    NEW.work_request_id,
    NULL,
    NULL,
    NEW.id,
    NULL,
    json_object('from', OLD.status, 'to', NEW.status),
    NULL,
    NEW.updated_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
END;

CREATE TRIGGER trg_history_step_created
AFTER INSERT ON workflow_tasks
BEGIN
  INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event',
    'workflow.step_created',
    'conclave',
    NULL,
    NEW.work_request_id,
    NULL,
    NULL,
    NEW.id,
    NULL,
    json_object('status', NEW.status, 'stepKind', NEW.step_kind, 'attempt', NEW.attempt),
    NULL,
    NEW.created_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
END;

CREATE TRIGGER trg_history_step_status
AFTER UPDATE OF status ON workflow_tasks
WHEN OLD.status IS NOT NEW.status
BEGIN
  INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'workflow_event',
    'workflow.step_status_changed',
    'conclave',
    NULL,
    NEW.work_request_id,
    NULL,
    NULL,
    NEW.id,
    NULL,
    json_object('from', OLD.status, 'to', NEW.status, 'stepKind', NEW.step_kind, 'attempt', NEW.attempt),
    NULL,
    NEW.updated_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = NEW.work_request_id;
END;

CREATE TRIGGER trg_history_execution_created
AFTER INSERT ON conversation_turns
BEGIN
  INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.conversation_id), 0) + 1,
    'execution_event',
    'execution.created',
    'conclave',
    NULL,
    NEW.work_request_id,
    NEW.id,
    NULL,
    NEW.id,
    NULL,
    json_object('workerId', NEW.worker_id, 'workerTypeId', NEW.worker_type_id, 'workerDisplayName', NEW.worker_display_name, 'profileId', NEW.profile_id, 'profileVersion', NEW.profile_version, 'modelId', NEW.model_id, 'effort', NEW.effort, 'workflowId', NEW.workflow_id, 'workflowVersion', NEW.workflow_version, 'userMessageId', NEW.user_message_id, 'assignmentId', NEW.assignment_id, 'taskId', NEW.task_id, 'stepKind', NEW.step_kind, 'workerSessionId', NEW.worker_session_id, 'baseContextRevision', NEW.base_context_revision),
    NULL,
    NEW.created_at
  ;
END;

CREATE TRIGGER trg_history_execution_status
AFTER UPDATE OF status ON conversation_turns
WHEN OLD.status IS NOT NEW.status
BEGIN
  INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.conversation_id), 0) + 1,
    'execution_event',
    'execution.' || CASE WHEN NEW.status = 'running' THEN 'started' ELSE NEW.status END,
    'conclave',
    NULL,
    NEW.work_request_id,
    NEW.id,
    NULL,
    NEW.id,
    NULL,
    json_object('from', OLD.status, 'to', NEW.status, 'assignmentId', NEW.assignment_id, 'startedAt', NEW.started_at, 'completedAt', NEW.completed_at),
    NULL,
    COALESCE(NEW.completed_at, NEW.started_at, NEW.created_at)
  ;
END;

CREATE TRIGGER trg_history_worker_response
AFTER UPDATE OF status ON conversation_turns
WHEN OLD.status IS NOT NEW.status AND NEW.status = 'completed' AND NEW.result_text IS NOT NULL
BEGIN
  INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.conversation_id), 0) + 1,
    'worker_response',
    'message.worker_created',
    'worker',
    NEW.worker_id,
    NEW.work_request_id,
    NEW.id,
    NULL,
    NEW.id,
    NEW.result_text,
    json_object('workerId', NEW.worker_id, 'workerTypeId', NEW.worker_type_id, 'workerDisplayName', NEW.worker_display_name, 'profileId', NEW.profile_id, 'profileVersion', NEW.profile_version, 'modelId', NEW.model_id, 'effort', NEW.effort, 'workflowId', NEW.workflow_id, 'workflowVersion', NEW.workflow_version, 'userMessageId', NEW.user_message_id, 'assignmentId', NEW.assignment_id, 'taskId', NEW.task_id, 'stepKind', NEW.step_kind, 'workerSessionId', NEW.worker_session_id, 'baseContextRevision', NEW.base_context_revision),
    'worker:' || NEW.id,
    NEW.completed_at
  ;
END;

CREATE TRIGGER trg_history_artifact_created
AFTER INSERT ON artifacts
BEGIN
  INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'artifact_event',
    'artifact.created',
    'conclave',
    NULL,
    cr.work_request_id,
    NULL,
    NEW.id,
    NEW.id,
    NULL,
    json_object('contentDigest', NEW.content_digest),
    NULL,
    NEW.created_at
  FROM conversation_work_requests cr WHERE cr.work_request_id = COALESCE(NEW.work_request_id, (SELECT wt.work_request_id FROM workflow_tasks wt JOIN worker_assignments wa ON wa.task_id = wt.id WHERE wa.id = NEW.assignment_id), (SELECT work_request_id FROM runs WHERE id = NEW.run_id));
END;

CREATE TRIGGER trg_history_artifact_removed
AFTER DELETE ON artifacts
BEGIN
  INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT cr.conversation_id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = cr.conversation_id), 0) + 1,
    'artifact_event',
    'artifact.removed',
    'conclave',
    NULL,
    cr.work_request_id,
    NULL,
    OLD.id,
    OLD.id,
    NULL,
    json_object('contentDigest', OLD.content_digest),
    NULL,
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  FROM conversation_work_requests cr WHERE cr.work_request_id = COALESCE(OLD.work_request_id, (SELECT wt.work_request_id FROM workflow_tasks wt JOIN worker_assignments wa ON wa.task_id = wt.id WHERE wa.id = OLD.assignment_id), (SELECT work_request_id FROM runs WHERE id = OLD.run_id));
END;

CREATE TRIGGER trg_history_context_revision
AFTER UPDATE OF context_revision ON conversations
WHEN NEW.context_revision > OLD.context_revision
BEGIN
  INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
  SELECT NEW.id,
    COALESCE((SELECT MAX(sequence) FROM conversation_history_entries WHERE conversation_id = NEW.id), 0) + 1,
    'context_event',
    'context.revision_advanced',
    'conclave',
    NULL,
    NULL,
    NULL,
    NULL,
    NEW.id,
    NULL,
    json_object('previousRevision', OLD.context_revision, 'contextRevision', NEW.context_revision),
    NULL,
    NEW.updated_at
  ;
END;

-- Seed authoritative existing facts in deterministic observed-time order.
-- Imported snapshots explicitly do not reconstruct missing past transitions.
WITH seed (conversation_id, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at, rank) AS (
  SELECT m.conversation_id, 'user_message', 'message.user_created', 'user', m.author_user_id, m.work_request_id, NULL, NULL, m.id, m.text, json_object('userMessageId', m.id), 'user:' || m.id, m.created_at, 0 FROM conversation_user_messages m
  UNION ALL
  SELECT cr.conversation_id, 'workflow_event', 'workflow.request_snapshot_imported', 'conclave', NULL, wr.id, NULL, NULL, wr.id, NULL, json_object('workflowId', wr.workflow_id, 'workflowVersion', wr.workflow_version, 'status', wr.status, 'imported', json('true')), NULL, wr.updated_at, 1 FROM work_requests wr JOIN conversation_work_requests cr ON cr.work_request_id = wr.id
  UNION ALL
  SELECT t.conversation_id, 'execution_event', 'execution.snapshot_imported', 'conclave', NULL, t.work_request_id, t.id, NULL, t.id, NULL, json_object('status', t.status, 'startedAt', t.started_at, 'completedAt', t.completed_at, 'imported', json('true')), NULL, t.created_at, 2 FROM conversation_turns t
  UNION ALL
  SELECT t.conversation_id, 'worker_response', 'message.worker_created', 'worker', t.worker_id, t.work_request_id, t.id, NULL, t.id, t.result_text, json_object('workerId', t.worker_id, 'workerTypeId', t.worker_type_id, 'workerDisplayName', t.worker_display_name, 'profileId', t.profile_id, 'profileVersion', t.profile_version, 'modelId', t.model_id, 'effort', t.effort, 'workflowId', t.workflow_id, 'workflowVersion', t.workflow_version, 'userMessageId', t.user_message_id, 'assignmentId', t.assignment_id, 'taskId', t.task_id, 'stepKind', t.step_kind, 'workerSessionId', t.worker_session_id, 'baseContextRevision', t.base_context_revision), 'worker:' || t.id, t.completed_at, 3 FROM conversation_turns t WHERE t.status = 'completed' AND t.result_text IS NOT NULL
  UNION ALL
  SELECT cr.conversation_id, 'artifact_event', 'artifact.snapshot_imported', 'conclave', NULL, cr.work_request_id, NULL, a.id, a.id, NULL, json_object('contentDigest', a.content_digest, 'imported', json('true')), NULL, a.created_at, 4 FROM artifacts a JOIN conversation_work_requests cr ON cr.work_request_id = COALESCE(a.work_request_id, (SELECT wt.work_request_id FROM workflow_tasks wt JOIN worker_assignments wa ON wa.task_id = wt.id WHERE wa.id = a.assignment_id), (SELECT work_request_id FROM runs WHERE id = a.run_id))
)
INSERT INTO conversation_history_entries (conversation_id, sequence, kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at)
SELECT conversation_id, ROW_NUMBER() OVER (PARTITION BY conversation_id ORDER BY occurred_at, rank, source_id),
  kind, event_type, actor_type, actor_id, work_request_id, turn_id, artifact_id, source_id, text, metadata_json, deduplication_key, occurred_at FROM seed;
