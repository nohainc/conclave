CREATE TABLE IF NOT EXISTS run_ci_evidence (
  evidence_id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(id),
  organization_id TEXT NOT NULL REFERENCES organizations(id),
  repository_id TEXT NOT NULL,
  commit_sha TEXT NOT NULL,
  workflow TEXT NOT NULL,
  external_run_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('claimed', 'consumed')),
  claimed_at TEXT NOT NULL,
  consumed_at TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_run_ci_evidence_run_external
  ON run_ci_evidence(run_id, external_run_id);
CREATE INDEX IF NOT EXISTS idx_run_ci_evidence_run
  ON run_ci_evidence(run_id, claimed_at);
