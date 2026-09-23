-- V4-10 makes Worker installation state explicit. Preserve existing
-- development records while replacing the old status constraint.
PRAGMA foreign_keys = OFF;

CREATE TABLE host_worker_installations_v4 (
  id TEXT PRIMARY KEY,
  host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
  worker_id TEXT NOT NULL REFERENCES workers(id) ON DELETE CASCADE,
  worker_version_id TEXT NOT NULL REFERENCES worker_versions(id),
  status TEXT NOT NULL CHECK (status IN (
    'absent', 'requested', 'downloading', 'verifying', 'installing',
    'ready', 'updating', 'degraded', 'failed', 'removing'
  )),
  error TEXT,
  installed_at TEXT,
  updated_at TEXT NOT NULL,
  UNIQUE (host_id, worker_id, worker_version_id)
);

INSERT INTO host_worker_installations_v4
  (id, host_id, worker_id, worker_version_id, status, error, installed_at, updated_at)
SELECT id, host_id, worker_id, worker_version_id,
  CASE status
    WHEN 'active' THEN 'ready'
    WHEN 'installed' THEN 'ready'
    WHEN 'error' THEN 'failed'
    WHEN 'removed' THEN 'absent'
    ELSE status
  END,
  error, installed_at, updated_at
FROM host_worker_installations;

DROP TABLE host_worker_installations;
ALTER TABLE host_worker_installations_v4 RENAME TO host_worker_installations;

CREATE INDEX idx_host_worker_installations_host
  ON host_worker_installations(host_id, status);

PRAGMA foreign_keys = ON;
