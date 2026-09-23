-- V4-11 setup intents are metadata-only requests for Host-local account work.
-- Raw credentials never enter this table.
CREATE TABLE credential_setup_intents (
  id TEXT PRIMARY KEY,
  credential_profile_id TEXT NOT NULL REFERENCES credential_profiles(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
  requested_by_user_id TEXT NOT NULL REFERENCES users(id),
  status TEXT NOT NULL DEFAULT 'requested'
    CHECK (status IN ('requested', 'in_progress', 'completed', 'failed', 'cancelled')),
  action TEXT NOT NULL CHECK (action IN ('setup', 'reauthenticate', 'clear')),
  details_json TEXT NOT NULL DEFAULT '{}',
  requested_at TEXT NOT NULL,
  completed_at TEXT
);
CREATE INDEX idx_credential_setup_intents_host
  ON credential_setup_intents(host_id, status, requested_at);
