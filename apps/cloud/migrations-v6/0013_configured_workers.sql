-- EW-2: persist configured Workers separately from the Worker Type catalog.
-- The existing `workers` table is retained as the Worker Type/catalog table;
-- configured Workers are user-owned identities with explicit Workspace
-- bindings. Credential material remains in Workspace secure storage.

CREATE TABLE configured_workers (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  name TEXT NOT NULL,
  worker_type_id TEXT NOT NULL REFERENCES workers(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'disabled', 'revoked')),
  default_model TEXT,
  config_json TEXT NOT NULL DEFAULT '{}',
  concurrency_limit INTEGER NOT NULL CHECK (concurrency_limit > 0),
  cost_metadata_json TEXT,
  preferred_roles_json TEXT NOT NULL DEFAULT '[]',
  allowed_roles_json TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (owner_user_id, name),
  UNIQUE (id, owner_user_id)
);

CREATE INDEX idx_v6_configured_workers_worker_type
  ON configured_workers(worker_type_id);
CREATE INDEX idx_v6_configured_workers_status
  ON configured_workers(status);
CREATE INDEX idx_v6_configured_workers_active_eligibility
  ON configured_workers(status, worker_type_id, owner_user_id)
  WHERE status = 'active';

CREATE TABLE worker_workspace_bindings (
  worker_id TEXT NOT NULL REFERENCES configured_workers(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
  desired_version_policy TEXT NOT NULL,
  local_readiness TEXT NOT NULL DEFAULT 'unknown'
    CHECK (local_readiness IN ('unknown', 'setup_required', 'ready', 'degraded', 'failed', 'revoked')),
  package_status TEXT NOT NULL DEFAULT 'absent'
    CHECK (package_status IN ('absent', 'installing', 'ready', 'updating', 'failed')),
  credential_status TEXT NOT NULL DEFAULT 'unknown'
    CHECK (credential_status IN ('unknown', 'setup_required', 'ready', 'expired', 'error')),
  permissions_status TEXT NOT NULL DEFAULT 'unknown'
    CHECK (permissions_status IN ('unknown', 'checking', 'ready', 'denied', 'error')),
  last_seen TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (worker_id, workspace_id)
);

CREATE INDEX idx_v6_worker_bindings_workspace
  ON worker_workspace_bindings(workspace_id, enabled);
CREATE INDEX idx_v6_worker_bindings_readiness
  ON worker_workspace_bindings(local_readiness, package_status, credential_status, permissions_status);
CREATE INDEX idx_v6_worker_bindings_active_eligibility
  ON worker_workspace_bindings(workspace_id, worker_id)
  WHERE enabled = 1
    AND local_readiness = 'ready'
    AND package_status = 'ready'
    AND credential_status = 'ready'
    AND permissions_status = 'ready';

-- Internal metadata for a Worker identity's Workspace-local credential state.
-- local_secret_ref is an opaque secure-store reference, never raw secret data.
CREATE TABLE workspace_worker_credentials (
  id TEXT PRIMARY KEY,
  worker_id TEXT NOT NULL REFERENCES configured_workers(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  auth_type TEXT NOT NULL CHECK (auth_type IN ('none', 'api_key', 'oauth', 'session_token', 'local')),
  sharing_policy TEXT NOT NULL CHECK (sharing_policy IN ('private_only', 'explicit_project')),
  provider_metadata_json TEXT NOT NULL DEFAULT '{}',
  local_secret_ref TEXT,
  state TEXT NOT NULL DEFAULT 'setup_required'
    CHECK (state IN ('setup_required', 'ready', 'expired', 'error', 'revoked')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (worker_id, workspace_id),
  FOREIGN KEY (worker_id, owner_user_id)
    REFERENCES configured_workers(id, owner_user_id)
);

CREATE INDEX idx_v6_workspace_worker_credentials_workspace
  ON workspace_worker_credentials(workspace_id, state);
CREATE INDEX idx_v6_workspace_worker_credentials_ready
  ON workspace_worker_credentials(worker_id, workspace_id)
  WHERE state = 'ready';
