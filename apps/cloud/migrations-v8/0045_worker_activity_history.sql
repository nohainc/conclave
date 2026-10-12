-- Keep a bounded, sanitized history projection for important Worker Activity.
-- The realtime_events table remains the replay source; this table provides a
-- compact assignment-scoped history and an independent retention boundary.

CREATE TABLE worker_activity_history (
  history_id TEXT PRIMARY KEY,
  assignment_id TEXT NOT NULL REFERENCES worker_assignments(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  attempt_id TEXT NOT NULL,
  execution_id TEXT NOT NULL,
  worker_id TEXT NOT NULL,
  source_event_id TEXT NOT NULL,
  provider_sequence INTEGER NOT NULL CHECK (provider_sequence > 0),
  event_type TEXT NOT NULL CHECK (event_type IN (
    'execution.started',
    'model.started',
    'tool.started',
    'tool.completed',
    'tool.failed',
    'execution.completed',
    'execution.failed',
    'execution.cancelled'
  )),
  status TEXT NOT NULL CHECK (status IN ('running', 'completed', 'failed', 'cancelled')),
  activity_id TEXT,
  title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 256),
  details_json TEXT NOT NULL DEFAULT '{}',
  occurred_at TEXT NOT NULL,
  UNIQUE (assignment_id, attempt_id, source_event_id),
  UNIQUE (assignment_id, attempt_id, provider_sequence)
);

CREATE INDEX idx_worker_activity_history_assignment
  ON worker_activity_history(assignment_id, occurred_at, provider_sequence);

CREATE INDEX idx_worker_activity_history_workspace
  ON worker_activity_history(workspace_id, occurred_at);

CREATE INDEX idx_realtime_events_assignment_activity
  ON realtime_events(assignment_id, event_type, occurred_at, sequence);
