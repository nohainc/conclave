-- P11/I3: keep the domain run ID separate from the durable Workflow instance ID.
ALTER TABLE runs ADD COLUMN workflow_instance_id TEXT;
CREATE INDEX IF NOT EXISTS idx_runs_workflow_instance
  ON runs(workflow_instance_id);
