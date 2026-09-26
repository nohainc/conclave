-- Phase 3: collapse Worker ownership onto Workspace-created V7 Workers.
-- Keep historical assignment attribution queryable before dropping the V6 FK.
UPDATE worker_assignments
   SET workspace_worker_id = COALESCE(workspace_worker_id, configured_worker_id);
DROP INDEX IF EXISTS idx_v6_worker_assignments_configured_worker;
ALTER TABLE worker_assignments DROP COLUMN configured_worker_id;

-- Preserve legacy audit history without keeping the V6 Worker ownership graph.
CREATE TABLE worker_attribution_audit_archive (
  id TEXT PRIMARY KEY,
  worker_id TEXT NOT NULL,
  workspace_id TEXT,
  worker_type_id TEXT,
  actor_type TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  action TEXT NOT NULL,
  target_id TEXT NOT NULL,
  details_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);
INSERT OR IGNORE INTO worker_attribution_audit_archive
  (id, worker_id, workspace_id, worker_type_id, actor_type, actor_id,
   action, target_id, details_json, created_at)
SELECT a.id, a.configured_worker_id, a.workspace_id, cw.worker_type_id,
       a.actor_type, a.actor_id, a.action, a.target_id, a.details_json, a.created_at
  FROM configured_worker_audit_log a
  LEFT JOIN configured_workers cw ON cw.id = a.configured_worker_id;
CREATE INDEX idx_worker_attribution_audit_worker
  ON worker_attribution_audit_archive(worker_id, workspace_id, created_at);

DROP TABLE IF EXISTS configured_worker_observability_metrics;
DROP TABLE IF EXISTS configured_worker_installations;
DROP TABLE IF EXISTS workspace_worker_credentials;
DROP TABLE IF EXISTS worker_workspace_bindings;
DROP TABLE IF EXISTS configured_worker_audit_log;
DROP TABLE IF EXISTS configured_worker_runtime_state;
DROP TABLE IF EXISTS configured_workers;
