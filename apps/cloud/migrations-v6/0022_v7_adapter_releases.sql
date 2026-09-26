-- Signed V7 Worker Type adapter releases. Package trust is still verified by
-- the Workspace against the manifest's publisher signature before install.
CREATE TABLE v7_adapter_releases (
  publisher_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  worker_type_id TEXT NOT NULL,
  version TEXT NOT NULL,
  release_channel TEXT NOT NULL CHECK (release_channel IN ('stable', 'beta', 'development')),
  protocol_version TEXT NOT NULL,
  supported_platforms_json TEXT NOT NULL,
  manifest_json TEXT NOT NULL,
  package_digest TEXT NOT NULL CHECK (length(package_digest) = 64),
  archive_sha256 TEXT NOT NULL CHECK (length(archive_sha256) = 64),
  package_r2_key TEXT NOT NULL UNIQUE,
  is_revoked INTEGER NOT NULL DEFAULT 0 CHECK (is_revoked IN (0, 1)),
  revoked_at TEXT,
  revocation_reason TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (worker_type_id, version)
);

CREATE INDEX idx_v7_adapter_release_channel
  ON v7_adapter_releases(worker_type_id, release_channel, is_revoked, created_at);
