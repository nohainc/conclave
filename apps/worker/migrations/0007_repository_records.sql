-- Durable repository envelope for records whose normalized tables are not yet
-- exposed by the first adapter generation. It preserves exact domain JSON and
-- tenant scope across Worker restarts while normalized projections evolve.
CREATE TABLE IF NOT EXISTS persistence_records (
  repository TEXT NOT NULL,
  record_id TEXT NOT NULL,
  organization_id TEXT,
  record_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (repository, record_id)
);
CREATE INDEX IF NOT EXISTS idx_persistence_records_tenant
  ON persistence_records(repository, organization_id, updated_at);
