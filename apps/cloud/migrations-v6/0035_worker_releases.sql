-- Native, platform-specific Worker release catalog. Development release data
-- is recreated from the Worker publish workflow; no adapter data migration.
DROP TABLE IF EXISTS v7_adapter_releases;

CREATE TABLE worker_releases (
  publisher_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  worker_type_id TEXT NOT NULL,
  version TEXT NOT NULL,
  platform TEXT NOT NULL CHECK (platform IN (
    'macos-arm64', 'macos-x64', 'linux-arm64', 'linux-x64',
    'windows-arm64', 'windows-x64'
  )),
  release_channel TEXT NOT NULL CHECK (release_channel IN ('stable', 'beta', 'development')),
  protocol_min TEXT NOT NULL,
  protocol_max TEXT NOT NULL,
  state_read_min INTEGER NOT NULL CHECK (state_read_min > 0),
  state_read_max INTEGER NOT NULL CHECK (state_read_max >= state_read_min),
  state_write INTEGER NOT NULL CHECK (state_write BETWEEN state_read_min AND state_read_max),
  capabilities_json TEXT NOT NULL,
  manifest_json TEXT NOT NULL,
  package_digest TEXT NOT NULL CHECK (length(package_digest) = 64),
  archive_sha256 TEXT NOT NULL CHECK (length(archive_sha256) = 64),
  package_r2_key TEXT NOT NULL UNIQUE,
  is_revoked INTEGER NOT NULL DEFAULT 0 CHECK (is_revoked IN (0, 1)),
  revoked_at TEXT,
  revocation_reason TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (worker_type_id, version, platform)
);

CREATE INDEX idx_worker_release_catalog
  ON worker_releases(platform, worker_type_id, release_channel, is_revoked, created_at);
