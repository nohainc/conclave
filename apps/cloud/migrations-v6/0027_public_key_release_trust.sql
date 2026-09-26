-- The clean v6 baseline does not include the legacy v4 host_releases table.
-- Bootstrap the current Workspace release schema here for clean installations;
-- CREATE IF NOT EXISTS also preserves a pre-existing compatible table.
CREATE TABLE IF NOT EXISTS host_releases (
  version TEXT PRIMARY KEY,
  channel TEXT NOT NULL DEFAULT 'stable'
    CHECK (channel IN ('stable', 'beta', 'development')),
  min_supported_agent_version TEXT,
  supported_os_json TEXT NOT NULL DEFAULT '["macos","linux","windows"]',
  supported_arch_json TEXT NOT NULL DEFAULT '["arm64","x64"]',
  package_digest TEXT NOT NULL,
  package_r2_key TEXT NOT NULL,
  signature TEXT NOT NULL,
  release_notes TEXT,
  is_revoked INTEGER NOT NULL DEFAULT 0 CHECK (is_revoked IN (0, 1)),
  revoked_at TEXT,
  revocation_reason TEXT,
  created_at TEXT NOT NULL
);

-- Workspace release signatures are verified by public keys. Key revocation is
-- published independently so already-installed clients can refresh the state.
ALTER TABLE host_releases ADD COLUMN signing_key_id TEXT;

CREATE TABLE release_signing_key_revocations (
  key_id TEXT PRIMARY KEY,
  revoked_at TEXT NOT NULL,
  revoked_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  reason TEXT NOT NULL
);
