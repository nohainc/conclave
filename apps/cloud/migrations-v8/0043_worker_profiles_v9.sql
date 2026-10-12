-- V9 additive Profile cutover.
--
-- Introduce one current Profile row per logical Worker and a compact immutable
-- history table before changing Cloud readers/writers. The V8 release/channel
-- tables remain intact until a later cleanup migration after the V9 code path
-- has been deployed and verified.

CREATE TABLE worker_profiles (
  worker_type_id TEXT PRIMARY KEY
    REFERENCES worker_catalog(worker_type_id) ON DELETE RESTRICT,
  schema_version INTEGER NOT NULL CHECK (schema_version >= 1),
  profile_json TEXT NOT NULL CHECK (
    json_valid(profile_json)
    AND length(profile_json) <= 262144
    AND json_extract(profile_json, '$.schemaVersion') = schema_version
  ),
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
  digest TEXT NOT NULL CHECK (
    length(digest) = 64
    AND digest NOT GLOB '*[^0-9a-f]*'
  ),
  signature TEXT NOT NULL CHECK (length(signature) > 0),
  signing_key_id TEXT NOT NULL CHECK (length(signing_key_id) > 0),
  updated_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (worker_type_id, revision)
);

CREATE TABLE worker_profile_history (
  worker_type_id TEXT NOT NULL
    REFERENCES worker_catalog(worker_type_id) ON DELETE RESTRICT,
  revision INTEGER NOT NULL CHECK (revision >= 1),
  schema_version INTEGER NOT NULL CHECK (schema_version >= 1),
  profile_json TEXT NOT NULL CHECK (
    json_valid(profile_json)
    AND length(profile_json) <= 262144
    AND json_extract(profile_json, '$.schemaVersion') = schema_version
  ),
  digest TEXT NOT NULL CHECK (
    length(digest) = 64
    AND digest NOT GLOB '*[^0-9a-f]*'
  ),
  signature TEXT NOT NULL CHECK (length(signature) > 0),
  signing_key_id TEXT NOT NULL CHECK (length(signing_key_id) > 0),
  actor_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  published_at TEXT NOT NULL,
  restoration_reason TEXT,
  PRIMARY KEY (worker_type_id, revision)
);

CREATE INDEX idx_worker_profile_history_worker_time
  ON worker_profile_history(worker_type_id, published_at DESC, revision DESC);

-- Seed the V9 current row from the approved stable Profile selected by the
-- existing V8 stable pointer. A malformed JSON payload, digest, or signature
-- fails the destination CHECK constraints and aborts the migration rather than
-- creating a partially migrated Worker.
INSERT INTO worker_profiles (
  worker_type_id, schema_version, profile_json, revision, digest, signature,
  signing_key_id, updated_by_user_id, updated_at
)
SELECT release.worker_type_id,
       release.schema_version,
       release.payload_json,
       release.release_version,
       release.payload_digest,
       release.signature,
       release.signing_key_id,
       release.updated_by_user_id,
       COALESCE(release.published_at, release.updated_at)
  FROM tool_profile_channel_pointers pointer
  JOIN tool_profile_releases release
    ON release.profile_definition_id = pointer.profile_definition_id
   AND release.release_version = pointer.release_version
  JOIN tool_profile_definitions definition
    ON definition.profile_definition_id = release.profile_definition_id
   AND definition.worker_type_id = release.worker_type_id
  JOIN worker_catalog worker
    ON worker.worker_type_id = release.worker_type_id
 WHERE pointer.channel = 'stable'
   AND release.lifecycle_state = 'stable'
   AND release.published_at IS NOT NULL
   AND definition.lifecycle_state = 'active'
   AND worker.lifecycle_state = 'active'
   AND worker.visibility_state = 'visible';

-- Preserve earlier stable snapshots for the same Profile Definition as
-- restorable V9 history. The currently selected revision is excluded because
-- it is already the current row. History is never an active channel.
INSERT INTO worker_profile_history (
  worker_type_id, revision, schema_version, profile_json, digest, signature,
  signing_key_id, actor_user_id, published_at, restoration_reason
)
SELECT release.worker_type_id,
       release.release_version,
       release.schema_version,
       release.payload_json,
       release.payload_digest,
       release.signature,
       release.signing_key_id,
       release.updated_by_user_id,
       release.published_at,
       NULL
  FROM tool_profile_releases release
  JOIN tool_profile_channel_pointers pointer
    ON pointer.profile_definition_id = release.profile_definition_id
   AND pointer.channel = 'stable'
  JOIN worker_profiles current_profile
    ON current_profile.worker_type_id = release.worker_type_id
   AND current_profile.revision <> release.release_version
 WHERE release.lifecycle_state = 'stable'
   AND release.published_at IS NOT NULL;
