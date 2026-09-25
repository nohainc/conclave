-- EW-4: make configured Worker bindings the declarative runtime desired state.
-- Package metadata belongs to the Worker Type release, while installation and
-- readiness belong to the configured Worker identity on one Workspace.

ALTER TABLE worker_versions ADD COLUMN publisher TEXT;
ALTER TABLE worker_versions ADD COLUMN protocol_version TEXT;
ALTER TABLE worker_versions ADD COLUMN supported_os_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE worker_versions ADD COLUMN supported_arch_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE worker_versions ADD COLUMN package_r2_key TEXT;
ALTER TABLE worker_versions ADD COLUMN signature TEXT;
ALTER TABLE worker_versions ADD COLUMN entrypoint TEXT;
ALTER TABLE worker_versions ADD COLUMN is_revoked INTEGER NOT NULL DEFAULT 0 CHECK (is_revoked IN (0, 1));

CREATE TABLE configured_worker_installations (
  id TEXT PRIMARY KEY,
  configured_worker_id TEXT NOT NULL REFERENCES configured_workers(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  worker_type_id TEXT NOT NULL REFERENCES workers(id) ON DELETE RESTRICT,
  worker_version_id TEXT,
  resolved_version TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('absent', 'requested', 'installing', 'ready', 'updating', 'degraded', 'failed', 'removing')),
  error TEXT,
  installed_at TEXT,
  updated_at TEXT NOT NULL,
  UNIQUE (workspace_id, configured_worker_id),
  FOREIGN KEY (worker_version_id, worker_type_id) REFERENCES worker_versions(id, worker_id)
);

CREATE INDEX idx_v6_configured_worker_installations_workspace
  ON configured_worker_installations(workspace_id, status);
CREATE INDEX idx_v6_configured_worker_installations_ready
  ON configured_worker_installations(configured_worker_id, workspace_id)
  WHERE status = 'ready';
