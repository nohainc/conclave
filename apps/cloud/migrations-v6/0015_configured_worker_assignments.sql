-- EW-6: preserve both configured Worker and Worker Type identities on an assignment.
ALTER TABLE worker_assignments ADD COLUMN configured_worker_id TEXT REFERENCES configured_workers(id) ON DELETE SET NULL;

CREATE INDEX idx_v6_worker_assignments_configured_worker
  ON worker_assignments(configured_worker_id, status);
