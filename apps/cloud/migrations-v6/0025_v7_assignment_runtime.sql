-- Phase 2 E2E: persist Workspace-owned V7 Worker attribution and dispatch state
-- directly on assignments. These columns intentionally have no dependency on
-- configured_workers, attempts, or the V6 tasks table.
ALTER TABLE worker_assignments ADD COLUMN workspace_worker_id TEXT;
ALTER TABLE worker_assignments ADD COLUMN task_id TEXT;
ALTER TABLE worker_assignments ADD COLUMN attempt_id TEXT;
ALTER TABLE worker_assignments ADD COLUMN worker_version TEXT;
ALTER TABLE worker_assignments ADD COLUMN model TEXT;
ALTER TABLE worker_assignments ADD COLUMN config_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE worker_assignments ADD COLUMN effective_permissions_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE worker_assignments ADD COLUMN permission_snapshot_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE worker_assignments ADD COLUMN timeout_ms INTEGER;
ALTER TABLE worker_assignments ADD COLUMN idempotency_key TEXT;

CREATE INDEX idx_v7_assignments_workspace_worker
  ON worker_assignments(workspace_worker_id, status);
