ALTER TABLE runs ADD COLUMN started_at TEXT;
ALTER TABLE runs ADD COLUMN finished_at TEXT;
ALTER TABLE runs ADD COLUMN workflow_instance_id TEXT;
ALTER TABLE runs ADD COLUMN policy_snapshot_json TEXT NOT NULL DEFAULT '{}';

CREATE UNIQUE INDEX idx_runs_workflow_instance
  ON runs(workflow_instance_id)
  WHERE workflow_instance_id IS NOT NULL;

CREATE TABLE run_external_executions (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  execution_kind TEXT NOT NULL,
  external_id TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (run_id, execution_kind)
);
