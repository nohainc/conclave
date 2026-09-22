-- P0/P3: persist model call telemetry in a relational, tenant-scoped table.
CREATE TABLE IF NOT EXISTS model_calls (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  attempt_id TEXT NOT NULL REFERENCES attempts(id) ON DELETE CASCADE,
  worker_id TEXT NOT NULL REFERENCES workers(id),
  connection_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  request_artifact_id TEXT REFERENCES artifacts(id) ON DELETE SET NULL,
  response_artifact_id TEXT REFERENCES artifacts(id) ON DELETE SET NULL,
  status TEXT NOT NULL,
  input_tokens INTEGER,
  output_tokens INTEGER,
  started_at TEXT NOT NULL,
  finished_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_model_calls_attempt
  ON model_calls(attempt_id, started_at);
CREATE INDEX IF NOT EXISTS idx_model_calls_workspace
  ON model_calls(workspace_id, started_at);
