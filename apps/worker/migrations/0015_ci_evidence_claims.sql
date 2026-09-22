-- P12: persist CI evidence claims and correlate them to repository/run identity.
ALTER TABLE ci_evidence ADD COLUMN repository_id TEXT;
ALTER TABLE ci_evidence ADD COLUMN status TEXT NOT NULL DEFAULT 'available';
ALTER TABLE ci_evidence ADD COLUMN claimed_at TEXT;
ALTER TABLE ci_evidence ADD COLUMN consumed_at TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_ci_evidence_identity
  ON ci_evidence(run_id, repository_id, revision, workflow, external_run_id);
CREATE INDEX IF NOT EXISTS idx_ci_evidence_claims
  ON ci_evidence(run_id, status, observed_at);
