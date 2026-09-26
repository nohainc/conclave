-- Workspace release signatures are verified by public keys. Key revocation is
-- published independently so already-installed clients can refresh the state.
ALTER TABLE host_releases ADD COLUMN signing_key_id TEXT;

CREATE TABLE release_signing_key_revocations (
  key_id TEXT PRIMARY KEY,
  revoked_at TEXT NOT NULL,
  revoked_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  reason TEXT NOT NULL
);
