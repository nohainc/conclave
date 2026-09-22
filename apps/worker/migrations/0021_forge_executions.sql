CREATE TABLE forge_executions (
  execution_id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  workspace_id TEXT,
  status TEXT NOT NULL CHECK (status IN ('started', 'completed', 'failed', 'cancelled', 'needs_input')),
  result_artifact_id TEXT,
  error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_forge_executions_run ON forge_executions(run_id);
