-- User-reported execution failures. Report metadata never contains prompts or
-- provider output; those remain in their authoritative product records.
CREATE TABLE issue_reports (
  id TEXT PRIMARY KEY,
  public_reference TEXT NOT NULL UNIQUE,
  reporter_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  workspace_id TEXT REFERENCES execution_workspaces(id) ON DELETE SET NULL,
  request_id TEXT NOT NULL,
  assignment_id TEXT,
  attempt_key TEXT NOT NULL,
  component TEXT NOT NULL,
  error_code TEXT NOT NULL,
  failure_stage TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('open', 'investigating', 'resolved', 'dismissed')),
  diagnostic_state TEXT NOT NULL CHECK (diagnostic_state IN ('complete', 'partial', 'unavailable')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (reporter_user_id, attempt_key)
);

CREATE INDEX idx_issue_reports_reporter_created
  ON issue_reports(reporter_user_id, created_at DESC);
CREATE INDEX idx_issue_reports_fingerprint
  ON issue_reports(fingerprint, status, created_at DESC);
CREATE INDEX idx_issue_reports_request
  ON issue_reports(request_id, created_at DESC);

CREATE TABLE issue_report_diagnostics (
  report_id TEXT PRIMARY KEY REFERENCES issue_reports(id) ON DELETE CASCADE,
  schema_version INTEGER NOT NULL DEFAULT 1,
  diagnostic_json TEXT NOT NULL CHECK (json_valid(diagnostic_json)),
  bundle_key TEXT,
  bundle_sha256 TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE issue_report_events (
  id TEXT PRIMARY KEY,
  report_id TEXT NOT NULL REFERENCES issue_reports(id) ON DELETE CASCADE,
  actor_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL,
  from_status TEXT,
  to_status TEXT,
  details_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(details_json)),
  created_at TEXT NOT NULL
);

CREATE INDEX idx_issue_report_events_report
  ON issue_report_events(report_id, created_at, id);
