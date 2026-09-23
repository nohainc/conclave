-- Persist the Cloudflare Workflow identity separately from the domain Run.
-- This keeps workflow retries/idempotency recoverable after a Cloud restart.
PRAGMA foreign_keys = ON;

CREATE TABLE run_external_executions (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  execution_kind TEXT NOT NULL,
  external_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active', 'completed', 'failed', 'cancelled')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (run_id, execution_kind)
);

CREATE INDEX idx_run_external_executions_run
  ON run_external_executions(run_id, execution_kind);
