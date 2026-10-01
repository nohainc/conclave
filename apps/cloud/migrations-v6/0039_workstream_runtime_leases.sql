-- Runtime Workstream leases follow the ID-derived Workstream directory. They
-- do not require a repository checkout.
CREATE TABLE workstream_runtime_leases (
  id TEXT PRIMARY KEY,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
  work_request_id TEXT NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  fencing_token INTEGER NOT NULL CHECK (fencing_token > 0),
  status TEXT NOT NULL CHECK (status IN ('active', 'released', 'expired')),
  acquired_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  released_at TEXT,
  UNIQUE (workstream_id, fencing_token)
);
CREATE UNIQUE INDEX idx_workstream_one_active_runtime_lease
  ON workstream_runtime_leases(workstream_id) WHERE status = 'active';
CREATE INDEX idx_workstream_runtime_lease_request
  ON workstream_runtime_leases(work_request_id, status);
