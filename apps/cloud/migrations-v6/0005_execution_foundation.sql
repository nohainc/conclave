-- V6-24: execution resources required by the clean-room solo flow.
-- These are canonical v6 tables, not compatibility objects.

CREATE TABLE worker_versions (
  id TEXT PRIMARY KEY,
  worker_id TEXT NOT NULL REFERENCES workers(id) ON DELETE CASCADE,
  version TEXT NOT NULL,
  capabilities_json TEXT NOT NULL DEFAULT '[]',
  permissions_json TEXT NOT NULL DEFAULT '[]',
  package_digest TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE (worker_id, version),
  UNIQUE (id, worker_id)
);

CREATE TABLE workspace_worker_installations (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  worker_id TEXT NOT NULL REFERENCES workers(id) ON DELETE CASCADE,
  worker_version_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('requested', 'installing', 'ready', 'updating', 'degraded', 'failed', 'removing')),
  installed_at TEXT,
  updated_at TEXT NOT NULL,
  UNIQUE (workspace_id, worker_id),
  FOREIGN KEY (worker_version_id, worker_id) REFERENCES worker_versions(id, worker_id)
);

CREATE TABLE workspace_project_grants (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL,
  granted_by_user_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'revoked', 'expired')),
  scope TEXT NOT NULL CHECK (scope IN ('project_repository', 'selected_paths', 'full_workspace')),
  repository_mappings_json TEXT NOT NULL DEFAULT '[]',
  path_mappings_json TEXT NOT NULL DEFAULT '[]',
  allowed_worker_ids_json TEXT NOT NULL DEFAULT '[]',
  allowed_permissions_json TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  expires_at TEXT,
  UNIQUE (id, project_id, workspace_id),
  FOREIGN KEY (workspace_id, granted_by_user_id)
    REFERENCES execution_workspaces(id, owner_user_id)
);
CREATE INDEX idx_v6_workspace_project_grants_project
  ON workspace_project_grants(project_id, status);

CREATE TABLE project_account_grants (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES ai_accounts(id) ON DELETE CASCADE,
  granted_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked', 'expired')),
  created_at TEXT NOT NULL,
  UNIQUE (project_id, account_id)
);

ALTER TABLE worker_assignments ADD COLUMN workspace_project_grant_id TEXT REFERENCES workspace_project_grants(id) ON DELETE SET NULL;
ALTER TABLE worker_assignments ADD COLUMN error_json TEXT;
