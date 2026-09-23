CREATE TABLE realtime_event_cursors (
  workspace_id TEXT PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
  next_sequence INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE realtime_events (
  event_id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
  chat_id TEXT REFERENCES chats(id) ON DELETE SET NULL,
  run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
  task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
  attempt_id TEXT REFERENCES attempts(id) ON DELETE SET NULL,
  assignment_id TEXT REFERENCES worker_assignments(id) ON DELETE SET NULL,
  host_id TEXT REFERENCES hosts(id) ON DELETE SET NULL,
  sequence INTEGER NOT NULL,
  event_type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  UNIQUE (workspace_id, sequence),
  UNIQUE (workspace_id, idempotency_key)
);
CREATE INDEX idx_realtime_events_workspace_sequence
  ON realtime_events(workspace_id, sequence);
