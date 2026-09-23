-- V4-19 Host desired state. Cloud owns this desired state; Hosts reconcile it
-- locally and report observed installation status over the Host protocol.
PRAGMA foreign_keys = ON;

CREATE TABLE host_desired_states (
  host_id TEXT PRIMARY KEY REFERENCES hosts(id) ON DELETE CASCADE,
  release_channel TEXT NOT NULL DEFAULT 'stable'
    CHECK (release_channel IN ('stable', 'beta', 'development')),
  credential_setup_requests_json TEXT NOT NULL DEFAULT '[]',
  local_permission_requests_json TEXT NOT NULL DEFAULT '[]',
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
  updated_at TEXT NOT NULL
);

CREATE TABLE host_desired_workers (
  host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
  worker_id TEXT NOT NULL REFERENCES workers(id) ON DELETE CASCADE,
  required_version TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (host_id, worker_id),
  FOREIGN KEY (worker_id, required_version)
    REFERENCES worker_versions(worker_id, version)
);

CREATE INDEX idx_host_desired_workers_host
  ON host_desired_workers(host_id, required_version);
