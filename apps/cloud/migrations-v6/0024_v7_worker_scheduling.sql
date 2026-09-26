-- Cloud-owned operational scheduling state for Workspace-owned V7 Workers.
-- New inventory is disabled until an owner explicitly enables scheduling.
ALTER TABLE workspace_worker_inventory ADD COLUMN removed_by_snapshot INTEGER NOT NULL DEFAULT 0 CHECK (removed_by_snapshot IN (0, 1));
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
INSERT OR IGNORE INTO v7_worker_scheduling (worker_id, state, updated_at)
SELECT worker_id, 'disabled', updated_at FROM workspace_worker_inventory;

CREATE TABLE v7_worker_scheduling_audit (
  id TEXT PRIMARY KEY,
  worker_id TEXT NOT NULL REFERENCES workspace_worker_inventory(worker_id) ON DELETE CASCADE,
  actor_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  action TEXT NOT NULL CHECK (action IN ('enabled', 'disabled', 'drain_requested', 'drain_completed')),
  requested_at TEXT NOT NULL,
  completed_at TEXT,
  details_json TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX idx_v7_worker_scheduling_audit_worker ON v7_worker_scheduling_audit(worker_id, requested_at);
