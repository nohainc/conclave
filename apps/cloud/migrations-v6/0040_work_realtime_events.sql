-- Durable Cloud realtime storage for Work lifecycle events. Keep this table
-- independent of the historical v4 workspace/project foreign-key topology.
CREATE TABLE IF NOT EXISTS realtime_event_cursors (
  workspace_id TEXT PRIMARY KEY,
  next_sequence INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS realtime_events (
  event_id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  project_id TEXT,
  chat_id TEXT,
  run_id TEXT,
  task_id TEXT,
  attempt_id TEXT,
  assignment_id TEXT,
  host_id TEXT,
  sequence INTEGER NOT NULL,
  event_type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  UNIQUE (workspace_id, sequence),
  UNIQUE (workspace_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_realtime_events_workspace_sequence
  ON realtime_events(workspace_id, sequence);
