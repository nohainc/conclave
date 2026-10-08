-- Conversation Continuity Phase 1: product identity above Work execution.
CREATE TABLE conversations (
  id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  workflow_id TEXT NOT NULL CHECK (workflow_id IN ('chat', 'work')),
  workflow_version INTEGER NOT NULL CHECK (workflow_version > 0),
  conversation_revision INTEGER NOT NULL DEFAULT 0 CHECK (conversation_revision >= 0),
  context_revision INTEGER NOT NULL DEFAULT 0 CHECK (context_revision >= 0 AND context_revision <= conversation_revision),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (thread_id, workflow_id)
);

CREATE TABLE conversation_work_requests (
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  work_request_id TEXT PRIMARY KEY REFERENCES work_requests(id) ON DELETE CASCADE,
  conversation_revision INTEGER NOT NULL CHECK (conversation_revision > 0),
  UNIQUE (conversation_id, conversation_revision)
);

CREATE TRIGGER trg_conversation_identity_immutable
BEFORE UPDATE OF id, thread_id, workflow_id, workflow_version ON conversations
WHEN OLD.id IS NOT NEW.id OR OLD.thread_id IS NOT NEW.thread_id
  OR OLD.workflow_id IS NOT NEW.workflow_id OR OLD.workflow_version IS NOT NEW.workflow_version
BEGIN
  SELECT RAISE(ABORT, 'Conversation identity and Workflow are immutable');
END;

CREATE TRIGGER trg_conversation_revisions_monotonic
BEFORE UPDATE OF conversation_revision, context_revision ON conversations
WHEN NEW.conversation_revision < OLD.conversation_revision OR NEW.context_revision < OLD.context_revision
BEGIN
  SELECT RAISE(ABORT, 'Conversation revisions cannot decrease');
END;

CREATE TRIGGER trg_conversation_request_immutable
BEFORE UPDATE ON conversation_work_requests
BEGIN
  SELECT RAISE(ABORT, 'Conversation request associations are immutable');
END;
