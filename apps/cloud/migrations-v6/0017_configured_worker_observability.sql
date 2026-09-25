-- EW-12: configured Worker audit and operational metrics.
CREATE TABLE configured_worker_audit_log (
  id TEXT PRIMARY KEY,
  configured_worker_id TEXT NOT NULL REFERENCES configured_workers(id) ON DELETE CASCADE,
  workspace_id TEXT REFERENCES execution_workspaces(id) ON DELETE SET NULL,
  actor_type TEXT NOT NULL CHECK (actor_type IN ('user', 'workspace_runtime', 'system')),
  actor_id TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN (
    'worker.created', 'worker.updated', 'worker.revoked',
    'worker.workspace.bound', 'worker.workspace.unbound',
    'worker.credential.setup_requested', 'worker.credential.ready',
    'worker.credential.revoked'
  )),
  target_id TEXT NOT NULL,
  details_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);

CREATE INDEX idx_v6_configured_worker_audit_worker
  ON configured_worker_audit_log(configured_worker_id, created_at DESC);
CREATE INDEX idx_v6_configured_worker_audit_workspace
  ON configured_worker_audit_log(workspace_id, created_at DESC);

CREATE TABLE configured_worker_observability_metrics (
  id TEXT PRIMARY KEY,
  configured_worker_id TEXT NOT NULL REFERENCES configured_workers(id) ON DELETE CASCADE,
  worker_type_id TEXT NOT NULL REFERENCES workers(id) ON DELETE RESTRICT,
  workspace_id TEXT REFERENCES execution_workspaces(id) ON DELETE SET NULL,
  ready INTEGER NOT NULL DEFAULT 0 CHECK (ready IN (0, 1)),
  package_status TEXT NOT NULL,
  credential_status TEXT NOT NULL,
  permissions_status TEXT NOT NULL,
  active_assignments INTEGER NOT NULL DEFAULT 0,
  auth_failure INTEGER NOT NULL DEFAULT 0 CHECK (auth_failure IN (0, 1)),
  convergence_latency_ms INTEGER,
  recorded_at TEXT NOT NULL
);

CREATE INDEX idx_v6_configured_worker_metrics_worker
  ON configured_worker_observability_metrics(configured_worker_id, recorded_at DESC);
CREATE INDEX idx_v6_configured_worker_metrics_workspace
  ON configured_worker_observability_metrics(workspace_id, recorded_at DESC);
