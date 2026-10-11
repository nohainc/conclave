-- Internal issue investigation metadata.  Reports remain the durable user-facing
-- record; groups are an investigator-managed view over those records.
CREATE TABLE issue_report_groups (
  id TEXT PRIMARY KEY,
  public_reference TEXT NOT NULL UNIQUE,
  label TEXT NOT NULL,
  fingerprint TEXT,
  created_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

ALTER TABLE issue_reports ADD COLUMN worker_type_id TEXT;
ALTER TABLE issue_reports ADD COLUMN model_id TEXT;
ALTER TABLE issue_reports ADD COLUMN effort TEXT;
ALTER TABLE issue_reports ADD COLUMN engine_version TEXT;
ALTER TABLE issue_reports ADD COLUMN profile_definition_id TEXT;
ALTER TABLE issue_reports ADD COLUMN profile_release_version INTEGER;
ALTER TABLE issue_reports ADD COLUMN provider_tool_version TEXT;
ALTER TABLE issue_reports ADD COLUMN application_version TEXT;
ALTER TABLE issue_reports ADD COLUMN incident_group_id TEXT REFERENCES issue_report_groups(id) ON DELETE SET NULL;

CREATE INDEX idx_issue_reports_investigation_filters
  ON issue_reports(status, component, error_code, worker_type_id, created_at DESC);
CREATE INDEX idx_issue_reports_incident_group
  ON issue_reports(incident_group_id, created_at DESC);
CREATE INDEX idx_issue_report_groups_fingerprint
  ON issue_report_groups(fingerprint, updated_at DESC);
