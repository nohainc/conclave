-- Existing v6 databases still carry the earlier versioned-workflow schema.
-- The applied initial migration was later edited to define the built-in Work
-- v1 schema, but that edit did not change already-migrated databases. The old
-- snapshot trigger can therefore reference columns absent from work_requests.
--
-- Rebuild only while the Work execution tables are empty. If a deployment has
-- accepted Work data, stop for a deliberate data migration instead of
-- discarding or guessing how custom workflow snapshots map to built-in v1.
CREATE TABLE conclave_v8_work_schema_empty_guard (
  assertion INTEGER NOT NULL CHECK (assertion = 1)
);

INSERT INTO conclave_v8_work_schema_empty_guard (assertion)
SELECT CASE WHEN
  (SELECT COUNT(*) FROM work_requests) = 0
  AND (SELECT COUNT(*) FROM workflow_tasks) = 0
  AND (SELECT COUNT(*) FROM workflow_task_dependencies) = 0
  AND (SELECT COUNT(*) FROM workstream_execution_leases) = 0
  AND (SELECT COUNT(*) FROM workstream_runtime_leases) = 0
  AND (SELECT COUNT(*) FROM workstream_checkpoints) = 0
  AND (SELECT COUNT(*) FROM workstream_diff_artifacts
        WHERE work_request_id IS NOT NULL) = 0
  AND (SELECT COUNT(*) FROM runs WHERE work_request_id IS NOT NULL) = 0
  AND (SELECT COUNT(*) FROM worker_assignments
        WHERE work_request_id IS NOT NULL) = 0
  AND (SELECT COUNT(*) FROM artifacts WHERE work_request_id IS NOT NULL) = 0
THEN 1 ELSE 0 END;

DROP TRIGGER IF EXISTS trg_work_requests_snapshot_immutable;
DROP TABLE workflow_task_dependencies;
DROP TABLE workflow_tasks;
DROP TABLE work_requests;

CREATE TABLE work_requests (
  id TEXT PRIMARY KEY,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
  requested_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  mode TEXT NOT NULL CHECK (mode IN ('stateless', 'stateful')),
  workflow_id TEXT NOT NULL CHECK (
    workflow_id IN ('direct', 'research', 'plan_implement', 'implement_verify', 'full_cycle')
  ),
  workflow_version INTEGER NOT NULL CHECK (workflow_version > 0),
  workflow_snapshot_json TEXT NOT NULL,
  status TEXT NOT NULL CHECK (
    status IN ('queued', 'running', 'waiting', 'completed', 'failed', 'cancelled')
  ),
  primary_workspace_id TEXT REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  checkout_id TEXT REFERENCES workstream_checkouts(id) ON DELETE RESTRICT,
  input_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  snapshot_json TEXT NOT NULL DEFAULT '{}',
  cancel_requested_at TEXT
);
CREATE INDEX idx_v6_work_requests_workstream
  ON work_requests(workstream_id, status, created_at);

CREATE TABLE workflow_tasks (
  id TEXT PRIMARY KEY,
  work_request_id TEXT NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  step_kind TEXT NOT NULL CHECK (
    step_kind IN ('research', 'plan', 'implement', 'test', 'verify')
  ),
  execution_mode TEXT NOT NULL CHECK (
    execution_mode IN ('stateless_read', 'stateful_workstream')
  ),
  timeout_ms INTEGER NOT NULL CHECK (timeout_ms >= 1000),
  prompt_profile_version TEXT NOT NULL,
  status TEXT NOT NULL CHECK (
    status IN ('queued', 'running', 'waiting', 'completed', 'failed', 'cancelled')
  ),
  attempt INTEGER NOT NULL DEFAULT 0 CHECK (attempt >= 0),
  output_json TEXT,
  error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  started_at TEXT,
  finished_at TEXT,
  UNIQUE (work_request_id, step_kind)
);
CREATE TABLE workflow_task_dependencies (
  task_id TEXT NOT NULL REFERENCES workflow_tasks(id) ON DELETE CASCADE,
  depends_on_task_id TEXT NOT NULL REFERENCES workflow_tasks(id) ON DELETE RESTRICT,
  PRIMARY KEY (task_id, depends_on_task_id),
  CHECK (task_id <> depends_on_task_id)
);
CREATE INDEX idx_v6_workflow_tasks_request
  ON workflow_tasks(work_request_id, status, created_at);

CREATE TRIGGER trg_work_requests_snapshot_immutable
BEFORE UPDATE OF workstream_id, requested_by_user_id, mode, workflow_id,
  workflow_version, workflow_snapshot_json, snapshot_json,
  primary_workspace_id, checkout_id, input_json
ON work_requests
WHEN OLD.workstream_id IS NOT NEW.workstream_id
  OR OLD.requested_by_user_id IS NOT NEW.requested_by_user_id
  OR OLD.mode IS NOT NEW.mode
  OR OLD.workflow_id IS NOT NEW.workflow_id
  OR OLD.workflow_version IS NOT NEW.workflow_version
  OR OLD.workflow_snapshot_json IS NOT NEW.workflow_snapshot_json
  OR OLD.snapshot_json IS NOT NEW.snapshot_json
  OR OLD.primary_workspace_id IS NOT NEW.primary_workspace_id
  OR OLD.checkout_id IS NOT NEW.checkout_id
  OR OLD.input_json IS NOT NEW.input_json
BEGIN
  SELECT RAISE(ABORT, 'Work Request snapshots are immutable');
END;

DROP TABLE conclave_v8_work_schema_empty_guard;
