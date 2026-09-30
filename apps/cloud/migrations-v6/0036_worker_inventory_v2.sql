-- Development rebuild for the fixed first-party Worker catalog. Inventory and
-- scheduling history are reseeded from Workspace; no adapter-era projection
-- fields or rows are carried forward.
DROP TABLE v7_worker_scheduling_audit;
DROP TABLE v7_worker_scheduling;
DROP TABLE workspace_worker_inventory;

CREATE TABLE workspace_worker_inventory (
  worker_id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  worker_type_id TEXT NOT NULL,
  activation_state TEXT NOT NULL CHECK (activation_state IN ('enabled', 'disabled')),
  readiness_state TEXT NOT NULL CHECK (readiness_state IN (
    'not_probed', 'ready', 'setup_required', 'sign_in_required',
    'worker_runtime_unavailable', 'test_failed'
  )),
  readiness_issue_code TEXT,
  worker_runtime_version TEXT,
  provider_tool_name TEXT,
  provider_tool_version TEXT,
  capabilities_json TEXT NOT NULL DEFAULT '[]',
  local_concurrency_limit INTEGER NOT NULL CHECK (local_concurrency_limit BETWEEN 1 AND 1024),
  revision INTEGER NOT NULL CHECK (revision > 0),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  FOREIGN KEY (workspace_id, owner_user_id)
    REFERENCES execution_workspaces(id, owner_user_id)
);

CREATE INDEX idx_workspace_worker_inventory_owner
  ON workspace_worker_inventory(owner_user_id, updated_at);
CREATE INDEX idx_workspace_worker_inventory_workspace
  ON workspace_worker_inventory(workspace_id, worker_type_id);

CREATE TABLE v7_worker_scheduling (
  worker_id TEXT PRIMARY KEY REFERENCES workspace_worker_inventory(worker_id) ON DELETE CASCADE,
  state TEXT NOT NULL DEFAULT 'disabled' CHECK (state IN ('enabled', 'disabled', 'draining')),
  cloud_concurrency_limit INTEGER CHECK (cloud_concurrency_limit IS NULL OR cloud_concurrency_limit BETWEEN 1 AND 1024),
  updated_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  updated_at TEXT NOT NULL,
  drain_requested_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  drain_requested_at TEXT,
  drain_completed_at TEXT
);

CREATE TABLE v7_worker_scheduling_audit (
  id TEXT PRIMARY KEY,
  worker_id TEXT NOT NULL REFERENCES workspace_worker_inventory(worker_id) ON DELETE CASCADE,
  actor_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  action TEXT NOT NULL CHECK (action IN ('enabled', 'disabled', 'drain_requested', 'drain_completed')),
  requested_at TEXT NOT NULL,
  completed_at TEXT,
  details_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX idx_v7_worker_scheduling_audit_worker
  ON v7_worker_scheduling_audit(worker_id, requested_at);
