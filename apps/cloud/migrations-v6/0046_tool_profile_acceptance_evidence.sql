-- A stable Tool Profile pointer must be backed by real, digest-bound provider
-- acceptance. Evidence is immutable and scoped to one signed release payload.
CREATE TABLE tool_profile_acceptance_evidence (
  id TEXT PRIMARY KEY,
  profile_definition_id TEXT NOT NULL,
  release_version INTEGER NOT NULL,
  payload_digest TEXT NOT NULL CHECK (length(payload_digest) = 64),
  engine_version TEXT NOT NULL,
  provider_tool_version TEXT NOT NULL,
  evidence_json TEXT NOT NULL CHECK (length(evidence_json) <= 32768),
  submitted_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  accepted_at TEXT NOT NULL,
  submitted_at TEXT NOT NULL,
  UNIQUE (profile_definition_id, release_version, payload_digest),
  FOREIGN KEY (profile_definition_id, release_version)
    REFERENCES tool_profile_releases(profile_definition_id, release_version)
    ON DELETE RESTRICT
);

CREATE INDEX idx_tool_profile_acceptance_evidence_release
  ON tool_profile_acceptance_evidence(profile_definition_id, release_version, submitted_at DESC);

CREATE TRIGGER tool_profile_acceptance_evidence_immutable
BEFORE UPDATE ON tool_profile_acceptance_evidence
BEGIN
  SELECT RAISE(ABORT, 'Tool Profile acceptance evidence is immutable');
END;

CREATE TRIGGER tool_profile_acceptance_evidence_no_delete
BEFORE DELETE ON tool_profile_acceptance_evidence
BEGIN
  SELECT RAISE(ABORT, 'Tool Profile acceptance evidence cannot be deleted');
END;
