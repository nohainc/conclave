-- V7-9: safe projection of Workspace-owned local Worker inventory.
-- Provider secrets, secure-store references, and local paths are intentionally
-- absent. V6 bindings remain during the staged architecture migration.
CREATE TABLE workspace_worker_inventory (
  worker_id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  worker_type_id TEXT NOT NULL,
  name TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('ready', 'needs_attention', 'disabled', 'removed')),
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
  FOREIGN KEY (workspace_id, owner_user_id)
    REFERENCES execution_workspaces(id, owner_user_id)
);

CREATE INDEX idx_workspace_worker_inventory_owner_status
  ON workspace_worker_inventory(owner_user_id, status, updated_at);
CREATE INDEX idx_workspace_worker_inventory_workspace
  ON workspace_worker_inventory(workspace_id, status, name);
CREATE UNIQUE INDEX idx_workspace_worker_inventory_workspace_name
  ON workspace_worker_inventory(workspace_id, lower(name))
  WHERE status != 'removed';
