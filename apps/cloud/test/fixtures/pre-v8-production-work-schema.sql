PRAGMA foreign_keys = ON;

CREATE TABLE users (id TEXT PRIMARY KEY);
CREATE TABLE workstreams (id TEXT PRIMARY KEY);
CREATE TABLE execution_workspaces (id TEXT PRIMARY KEY);
CREATE TABLE workstream_checkouts (id TEXT PRIMARY KEY);
CREATE TABLE workflow_definitions (id TEXT PRIMARY KEY);
CREATE TABLE workflow_versions (
  id TEXT PRIMARY KEY,
  workflow_definition_id TEXT NOT NULL REFERENCES workflow_definitions(id),
  version INTEGER NOT NULL
);
CREATE TABLE workflow_steps (
  id TEXT PRIMARY KEY,
  workflow_version_id TEXT NOT NULL REFERENCES workflow_versions(id),
  UNIQUE (workflow_version_id, id)
);

CREATE TABLE work_requests (
  id TEXT PRIMARY KEY,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
  requested_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  mode TEXT NOT NULL CHECK (mode IN ('stateless', 'stateful')),
  workflow_definition_id TEXT NOT NULL REFERENCES workflow_definitions(id) ON DELETE RESTRICT,
  workflow_version_id TEXT NOT NULL REFERENCES workflow_versions(id) ON DELETE RESTRICT,
  workflow_snapshot_json TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'waiting', 'completed', 'failed', 'cancelled')),
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

CREATE TABLE workflow_tasks (
  id TEXT PRIMARY KEY,
  work_request_id TEXT NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  workflow_version_id TEXT NOT NULL REFERENCES workflow_versions(id) ON DELETE RESTRICT,
  workflow_step_id TEXT NOT NULL,
  execution_class TEXT NOT NULL,
  role TEXT NOT NULL,
  required_capabilities_json TEXT NOT NULL DEFAULT '[]',
  approval TEXT NOT NULL,
  timeout_ms INTEGER NOT NULL,
  output_contract_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL,
  attempt INTEGER NOT NULL DEFAULT 0,
  output_json TEXT,
  error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  started_at TEXT,
  finished_at TEXT,
  UNIQUE (work_request_id, workflow_step_id),
  FOREIGN KEY (workflow_version_id, workflow_step_id)
    REFERENCES workflow_steps(workflow_version_id, id) ON DELETE RESTRICT
);
CREATE TABLE workflow_task_dependencies (
  task_id TEXT NOT NULL REFERENCES workflow_tasks(id) ON DELETE CASCADE,
  depends_on_task_id TEXT NOT NULL REFERENCES workflow_tasks(id) ON DELETE RESTRICT,
  PRIMARY KEY (task_id, depends_on_task_id),
  CHECK (task_id <> depends_on_task_id)
);

CREATE TABLE workstream_execution_leases (
  id TEXT PRIMARY KEY,
  work_request_id TEXT NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE
);
CREATE TABLE workstream_runtime_leases (
  id TEXT PRIMARY KEY,
  work_request_id TEXT NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE
);
CREATE TABLE workstream_checkpoints (
  id TEXT PRIMARY KEY,
  created_by_work_request_id TEXT NOT NULL REFERENCES work_requests(id) ON DELETE RESTRICT
);
CREATE TABLE workstream_diff_artifacts (
  id TEXT PRIMARY KEY,
  work_request_id TEXT REFERENCES work_requests(id) ON DELETE SET NULL
);
CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  work_request_id TEXT REFERENCES work_requests(id) ON DELETE SET NULL,
  workflow_version_id TEXT REFERENCES workflow_versions(id) ON DELETE SET NULL
);
CREATE TABLE worker_assignments (
  id TEXT PRIMARY KEY,
  work_request_id TEXT REFERENCES work_requests(id) ON DELETE SET NULL,
  workflow_version_id TEXT REFERENCES workflow_versions(id) ON DELETE SET NULL,
  worker_version TEXT
);
CREATE TABLE artifacts (
  id TEXT PRIMARY KEY,
  work_request_id TEXT REFERENCES work_requests(id) ON DELETE SET NULL,
  workflow_version_id TEXT REFERENCES workflow_versions(id) ON DELETE SET NULL
);

CREATE TABLE workspace_worker_inventory (
  worker_id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  worker_type_id TEXT NOT NULL,
  activation_state TEXT NOT NULL,
  readiness_state TEXT NOT NULL,
  readiness_issue_code TEXT,
  worker_runtime_version TEXT,
  provider_tool_name TEXT,
  provider_tool_version TEXT,
  capabilities_json TEXT NOT NULL DEFAULT '[]',
  local_concurrency_limit INTEGER NOT NULL,
  revision INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL
);
CREATE TABLE worker_releases (id TEXT PRIMARY KEY);
