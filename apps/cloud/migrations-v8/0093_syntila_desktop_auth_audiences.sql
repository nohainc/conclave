-- Preserve desktop authentication records across the Conclave to Syntila rename.
-- Unknown audiences fail the new CHECK instead of being silently discarded.

CREATE TABLE desktop_auth_intents__syntila (
  id TEXT PRIMARY KEY,
  poll_token_hash TEXT NOT NULL,
  client_name TEXT NOT NULL,
  audience TEXT NOT NULL DEFAULT 'syntila.desktop.management' CHECK (audience IN ('syntila.desktop.management', 'syntila.profile-lab.management')),
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  approved_at TEXT,
  approved_user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
  claimed_at TEXT,
  claimed_session_id TEXT,
  denied_at TEXT
);

INSERT INTO desktop_auth_intents__syntila SELECT id, poll_token_hash, client_name, CASE audience WHEN 'conclave.desktop.management' THEN 'syntila.desktop.management' WHEN 'conclave.profile-lab.management' THEN 'syntila.profile-lab.management' ELSE audience END, created_at, expires_at, approved_at, approved_user_id, claimed_at, claimed_session_id, denied_at FROM desktop_auth_intents;
DROP INDEX idx_desktop_auth_intents_expiry;
DROP TABLE desktop_auth_intents;
ALTER TABLE desktop_auth_intents__syntila RENAME TO desktop_auth_intents;

CREATE INDEX idx_desktop_auth_intents_expiry
  ON desktop_auth_intents(expires_at)
  WHERE claimed_at IS NULL AND denied_at IS NULL;

CREATE TABLE desktop_human_sessions__syntila (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  audience TEXT NOT NULL CHECK (audience IN ('syntila.desktop.management', 'syntila.profile-lab.management')),
  created_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT
);

INSERT INTO desktop_human_sessions__syntila SELECT id, user_id, token_hash, CASE audience WHEN 'conclave.desktop.management' THEN 'syntila.desktop.management' WHEN 'conclave.profile-lab.management' THEN 'syntila.profile-lab.management' ELSE audience END, created_at, last_used_at, expires_at, revoked_at FROM desktop_human_sessions;
DROP INDEX idx_desktop_human_sessions_user;
DROP TABLE desktop_human_sessions;
ALTER TABLE desktop_human_sessions__syntila RENAME TO desktop_human_sessions;

CREATE INDEX idx_desktop_human_sessions_user
  ON desktop_human_sessions(user_id, created_at DESC);

