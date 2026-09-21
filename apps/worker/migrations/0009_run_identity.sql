-- Keep the domain run ID separate from every external execution provider.
ALTER TABLE runs ADD COLUMN workflow_instance_id TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS idx_runs_workflow_instance
  ON runs(workflow_instance_id);

CREATE TABLE IF NOT EXISTS run_external_executions (
  run_id TEXT NOT NULL,
  execution_type TEXT NOT NULL,
  workflow_instance_id TEXT NOT NULL,
  external_run_id TEXT,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (run_id, execution_type),
  UNIQUE (execution_type, workflow_instance_id)
);
CREATE INDEX IF NOT EXISTS idx_run_external_executions_instance
  ON run_external_executions(execution_type, workflow_instance_id);
