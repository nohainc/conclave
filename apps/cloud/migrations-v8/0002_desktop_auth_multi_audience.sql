-- `0001_conclave_v8.sql` was already applied in production before the
-- Profile Lab audience was added to its desktop auth tables. Rebuild both
-- tables so the deployed database receives the same constraints as a clean
-- database, while preserving every existing intent and session row.

CREATE TABLE __migration_0002_desktop_auth_counts (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  auth_intents_before INTEGER NOT NULL,
  human_sessions_before INTEGER NOT NULL
);

INSERT INTO __migration_0002_desktop_auth_counts (
  singleton,
  auth_intents_before,
  human_sessions_before
)
VALUES (
  1,
  (SELECT COUNT(*) FROM desktop_auth_intents),
  (SELECT COUNT(*) FROM desktop_human_sessions)
);

CREATE TABLE desktop_auth_intents__multi_audience (
  id TEXT PRIMARY KEY,
  poll_token_hash TEXT NOT NULL,
  client_name TEXT NOT NULL,
  audience TEXT NOT NULL DEFAULT 'conclave.desktop.management'
    CHECK (audience IN (
      'conclave.desktop.management',
      'conclave.profile-lab.management'
    )),
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  approved_at TEXT,
  approved_user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
  claimed_at TEXT,
  claimed_session_id TEXT,
  denied_at TEXT
);

-- The applied production baseline predates the intent audience column. Omitting
-- it here assigns the existing intents their original Workspace audience.
INSERT INTO desktop_auth_intents__multi_audience (
  id,
  poll_token_hash,
  client_name,
  created_at,
  expires_at,
  approved_at,
  approved_user_id,
  claimed_at,
  claimed_session_id,
  denied_at
)
SELECT
  id,
  poll_token_hash,
  client_name,
  created_at,
  expires_at,
  approved_at,
  approved_user_id,
  claimed_at,
  claimed_session_id,
  denied_at
FROM desktop_auth_intents;

DROP INDEX idx_desktop_auth_intents_expiry;
DROP TABLE desktop_auth_intents;
ALTER TABLE desktop_auth_intents__multi_audience RENAME TO desktop_auth_intents;

CREATE INDEX idx_desktop_auth_intents_expiry
  ON desktop_auth_intents(expires_at)
  WHERE claimed_at IS NULL AND denied_at IS NULL;

CREATE TABLE desktop_human_sessions__multi_audience (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  audience TEXT NOT NULL CHECK (audience IN (
    'conclave.desktop.management',
    'conclave.profile-lab.management'
  )),
  created_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT
);

INSERT INTO desktop_human_sessions__multi_audience (
  id,
  user_id,
  token_hash,
  audience,
  created_at,
  last_used_at,
  expires_at,
  revoked_at
)
SELECT
  id,
  user_id,
  token_hash,
  audience,
  created_at,
  last_used_at,
  expires_at,
  revoked_at
FROM desktop_human_sessions;

DROP INDEX idx_desktop_human_sessions_user;
DROP TABLE desktop_human_sessions;
ALTER TABLE desktop_human_sessions__multi_audience RENAME TO desktop_human_sessions;

CREATE INDEX idx_desktop_human_sessions_user
  ON desktop_human_sessions(user_id, created_at DESC);

-- CHECK makes a row-count mismatch abort this migration. Wrangler rolls back a
-- failed migration, so the original tables remain intact if verification fails.
CREATE TABLE __migration_0002_desktop_auth_count_assertion (
  counts_match INTEGER NOT NULL CHECK (counts_match = 1)
);

INSERT INTO __migration_0002_desktop_auth_count_assertion (counts_match)
SELECT CASE
  WHEN auth_intents_before = (SELECT COUNT(*) FROM desktop_auth_intents)
   AND human_sessions_before = (SELECT COUNT(*) FROM desktop_human_sessions)
  THEN 1
  ELSE 0
END
FROM __migration_0002_desktop_auth_counts;

DROP TABLE __migration_0002_desktop_auth_count_assertion;
DROP TABLE __migration_0002_desktop_auth_counts;
