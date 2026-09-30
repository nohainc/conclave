-- V7-13: retain package-reported setup readiness and its stable issue code.
-- Rebuild the inventory table because SQLite cannot extend its readiness_state
-- CHECK constraint in place. Preserve Cloud scheduling and audit rows while
-- replacing the parent table they reference.
CREATE TABLE _worker_scheduling_migration_copy AS
SELECT worker_id, state, cloud_concurrency_limit, updated_by_user_id,
       updated_at, drain_requested_by_user_id, drain_requested_at,
       drain_completed_at
  FROM v7_worker_scheduling;

CREATE TABLE _worker_scheduling_audit_migration_copy AS
SELECT id, worker_id, actor_user_id, action, requested_at, completed_at,
       details_json
  FROM v7_worker_scheduling_audit;

DROP TABLE v7_worker_scheduling_audit;
DROP TABLE v7_worker_scheduling;
DROP INDEX idx_workspace_worker_inventory_owner_status;
DROP INDEX idx_workspace_worker_inventory_workspace;
DROP INDEX idx_workspace_worker_inventory_workspace_name;

CREATE TABLE _workspace_worker_inventory_next (
  worker_id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  worker_type_id TEXT NOT NULL,
  name TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('ready', 'needs_attention', 'disabled', 'removed')),
  readiness_state TEXT NOT NULL DEFAULT 'test_failed' CHECK (readiness_state IN (
    'ready', 'setup_required', 'not_installed', 'sign_in_required',
    'unsupported_cli_version', 'adapter_unavailable', 'disabled', 'test_failed'
  )),
  readiness_issue_code TEXT,
  auth_strategy TEXT NOT NULL CHECK (auth_strategy IN ('none', 'browser_auth', 'api_key', 'local_endpoint')),
  default_model TEXT,
  allowed_models_json TEXT NOT NULL DEFAULT '[]',
  capabilities_json TEXT NOT NULL DEFAULT '[]',
  local_permissions_summary_json TEXT NOT NULL DEFAULT '[]',
  local_concurrency_limit INTEGER NOT NULL CHECK (local_concurrency_limit BETWEEN 1 AND 1024),
  adapter_version TEXT,
  credential_status TEXT NOT NULL CHECK (credential_status IN ('not_required', 'ready', 'needs_authentication', 'expired', 'error')),
  revision INTEGER NOT NULL CHECK (revision > 0),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  removed_at TEXT,
  removed_by_snapshot INTEGER NOT NULL DEFAULT 0 CHECK (removed_by_snapshot IN (0, 1)),
  FOREIGN KEY (workspace_id, owner_user_id)
    REFERENCES execution_workspaces(id, owner_user_id)
);

INSERT INTO _workspace_worker_inventory_next (
  worker_id, workspace_id, owner_user_id, worker_type_id, name, status,
  readiness_state, auth_strategy, default_model, allowed_models_json,
  capabilities_json, local_permissions_summary_json, local_concurrency_limit,
  adapter_version, credential_status, revision, created_at, updated_at,
  last_seen_at, removed_at, removed_by_snapshot
)
SELECT worker_id, workspace_id, owner_user_id, worker_type_id, name, status,
       readiness_state, auth_strategy, default_model, allowed_models_json,
       capabilities_json, local_permissions_summary_json, local_concurrency_limit,
       adapter_version, credential_status, revision, created_at, updated_at,
       last_seen_at, removed_at, removed_by_snapshot
  FROM workspace_worker_inventory;

DROP TABLE workspace_worker_inventory;
ALTER TABLE _workspace_worker_inventory_next RENAME TO workspace_worker_inventory;

CREATE INDEX idx_workspace_worker_inventory_owner_status
  ON workspace_worker_inventory(owner_user_id, status, updated_at);
CREATE INDEX idx_workspace_worker_inventory_workspace
  ON workspace_worker_inventory(workspace_id, status, name);
CREATE UNIQUE INDEX idx_workspace_worker_inventory_workspace_name
  ON workspace_worker_inventory(workspace_id, lower(name))
  WHERE status != 'removed';

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
INSERT INTO v7_worker_scheduling
SELECT worker_id, state, cloud_concurrency_limit, updated_by_user_id,
       updated_at, drain_requested_by_user_id, drain_requested_at,
       drain_completed_at
  FROM _worker_scheduling_migration_copy;

CREATE TABLE v7_worker_scheduling_audit (
  id TEXT PRIMARY KEY,
  worker_id TEXT NOT NULL REFERENCES workspace_worker_inventory(worker_id) ON DELETE CASCADE,
  actor_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  action TEXT NOT NULL CHECK (action IN ('enabled', 'disabled', 'drain_requested', 'drain_completed')),
  requested_at TEXT NOT NULL,
  completed_at TEXT,
  details_json TEXT NOT NULL DEFAULT '{}'
);
INSERT INTO v7_worker_scheduling_audit
SELECT id, worker_id, actor_user_id, action, requested_at, completed_at,
       details_json
  FROM _worker_scheduling_audit_migration_copy;
CREATE INDEX idx_v7_worker_scheduling_audit_worker
  ON v7_worker_scheduling_audit(worker_id, requested_at);

DROP TABLE _worker_scheduling_migration_copy;
DROP TABLE _worker_scheduling_audit_migration_copy;
