-- EW-15: keep the requester in the canonical assignment snapshot.
-- Usage attribution is derived from this immutable field rather than from a
-- caller-supplied value.
ALTER TABLE worker_assignments
  ADD COLUMN requested_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL;

CREATE INDEX idx_v6_worker_assignments_requester
  ON worker_assignments(requested_by_user_id, created_at);
