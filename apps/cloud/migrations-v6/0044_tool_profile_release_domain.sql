-- Architecture v8 separates stable logical Workers from immutable provider
-- Tool Profile releases. No provider-specific Worker release rows are copied.
-- Development data is disposable: clear native per-provider packages from the
-- old release catalog while leaving its migration-only schema for v2 cleanup.
DELETE FROM worker_releases;

CREATE TABLE worker_catalog (
  worker_type_id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 128),
  description TEXT NOT NULL DEFAULT '',
  lifecycle_state TEXT NOT NULL DEFAULT 'active'
    CHECK (lifecycle_state IN ('active', 'retired')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE tool_profile_definitions (
  profile_definition_id TEXT PRIMARY KEY,
  worker_type_id TEXT NOT NULL REFERENCES worker_catalog(worker_type_id) ON DELETE RESTRICT,
  display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 128),
  provider_tool_name TEXT NOT NULL CHECK (length(provider_tool_name) BETWEEN 1 AND 128),
  engine_family TEXT NOT NULL CHECK (engine_family = 'cli'),
  schema_version INTEGER NOT NULL CHECK (schema_version = 1),
  lifecycle_state TEXT NOT NULL DEFAULT 'active'
    CHECK (lifecycle_state IN ('active', 'retired')),
  created_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (profile_definition_id, worker_type_id)
);

CREATE INDEX idx_tool_profile_definitions_worker
  ON tool_profile_definitions(worker_type_id, lifecycle_state, profile_definition_id);

CREATE TABLE tool_profile_releases (
  profile_definition_id TEXT NOT NULL,
  release_version INTEGER NOT NULL CHECK (release_version BETWEEN 1 AND 2147483647),
  worker_type_id TEXT NOT NULL,
  lifecycle_state TEXT NOT NULL DEFAULT 'draft'
    CHECK (lifecycle_state IN ('draft', 'testing', 'beta', 'stable', 'retired', 'revoked')),
  schema_version INTEGER NOT NULL CHECK (schema_version = 1),
  engine_family TEXT NOT NULL CHECK (engine_family = 'cli'),
  engine_compatibility_min TEXT NOT NULL,
  engine_compatibility_max_exclusive TEXT NOT NULL,
  payload_json TEXT NOT NULL CHECK (length(payload_json) <= 262144),
  payload_digest TEXT NOT NULL CHECK (length(payload_digest) = 64),
  signature TEXT,
  signing_key_id TEXT,
  publisher TEXT,
  created_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  updated_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  published_at TEXT,
  lifecycle_reason TEXT,
  revoked_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (profile_definition_id, release_version),
  FOREIGN KEY (profile_definition_id, worker_type_id)
    REFERENCES tool_profile_definitions(profile_definition_id, worker_type_id)
    ON DELETE RESTRICT,
  CHECK ((published_at IS NULL AND signature IS NULL AND signing_key_id IS NULL)
      OR (published_at IS NOT NULL AND signature IS NOT NULL AND signing_key_id IS NOT NULL AND publisher IS NOT NULL))
);

CREATE INDEX idx_tool_profile_release_lifecycle
  ON tool_profile_releases(profile_definition_id, lifecycle_state, release_version DESC);
CREATE INDEX idx_tool_profile_release_worker
  ON tool_profile_releases(worker_type_id, lifecycle_state, profile_definition_id);

CREATE TABLE tool_profile_channel_pointers (
  profile_definition_id TEXT NOT NULL,
  channel TEXT NOT NULL CHECK (channel IN ('testing', 'beta', 'stable')),
  release_version INTEGER NOT NULL,
  modified_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (profile_definition_id, channel),
  FOREIGN KEY (profile_definition_id, release_version)
    REFERENCES tool_profile_releases(profile_definition_id, release_version)
    ON DELETE RESTRICT
);

CREATE TABLE tool_profile_release_audit (
  id TEXT PRIMARY KEY,
  profile_definition_id TEXT NOT NULL,
  release_version INTEGER NOT NULL,
  actor_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  action TEXT NOT NULL CHECK (action IN (
    'draft_created', 'published_for_testing', 'promoted_to_beta',
    'promoted_to_stable', 'retired', 'revoked', 'channel_promoted',
    'stable_rollback', 'channel_cleared'
  )),
  previous_release_version INTEGER,
  channel TEXT CHECK (channel IS NULL OR channel IN ('testing', 'beta', 'stable')),
  from_state TEXT,
  to_state TEXT,
  reason TEXT,
  details_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  FOREIGN KEY (profile_definition_id, release_version)
    REFERENCES tool_profile_releases(profile_definition_id, release_version)
    ON DELETE RESTRICT
);

CREATE INDEX idx_tool_profile_release_audit_history
  ON tool_profile_release_audit(profile_definition_id, release_version, created_at);

CREATE TRIGGER tool_profile_release_payload_immutable
BEFORE UPDATE OF profile_definition_id, release_version, worker_type_id,
  schema_version, engine_family, engine_compatibility_min,
  engine_compatibility_max_exclusive, payload_json, payload_digest,
  signature, signing_key_id, publisher, published_at
ON tool_profile_releases
WHEN OLD.published_at IS NOT NULL AND (
  OLD.profile_definition_id IS NOT NEW.profile_definition_id OR
  OLD.release_version IS NOT NEW.release_version OR
  OLD.worker_type_id IS NOT NEW.worker_type_id OR
  OLD.schema_version IS NOT NEW.schema_version OR
  OLD.engine_family IS NOT NEW.engine_family OR
  OLD.engine_compatibility_min IS NOT NEW.engine_compatibility_min OR
  OLD.engine_compatibility_max_exclusive IS NOT NEW.engine_compatibility_max_exclusive OR
  OLD.payload_json IS NOT NEW.payload_json OR
  OLD.payload_digest IS NOT NEW.payload_digest OR
  OLD.signature IS NOT NEW.signature OR
  OLD.signing_key_id IS NOT NEW.signing_key_id OR
  OLD.publisher IS NOT NEW.publisher OR
  OLD.published_at IS NOT NEW.published_at
)
BEGIN
  SELECT RAISE(ABORT, 'published Tool Profile release payload is immutable');
END;

CREATE TRIGGER tool_profile_published_release_no_delete
BEFORE DELETE ON tool_profile_releases
WHEN OLD.published_at IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'published Tool Profile releases cannot be deleted');
END;

CREATE TRIGGER tool_profile_lifecycle_transition_valid
BEFORE UPDATE OF lifecycle_state ON tool_profile_releases
WHEN OLD.lifecycle_state IS NOT NEW.lifecycle_state AND NOT (
  (OLD.lifecycle_state = 'draft' AND NEW.lifecycle_state IN ('testing', 'retired', 'revoked')) OR
  (OLD.lifecycle_state = 'testing' AND NEW.lifecycle_state IN ('beta', 'stable', 'retired', 'revoked')) OR
  (OLD.lifecycle_state = 'beta' AND NEW.lifecycle_state IN ('stable', 'retired', 'revoked')) OR
  (OLD.lifecycle_state = 'stable' AND NEW.lifecycle_state IN ('retired', 'revoked'))
)
BEGIN
  SELECT RAISE(ABORT, 'invalid Tool Profile lifecycle transition');
END;

CREATE TRIGGER tool_profile_release_draft_audit
AFTER INSERT ON tool_profile_releases
BEGIN
  INSERT INTO tool_profile_release_audit (
    id, profile_definition_id, release_version, actor_user_id, action,
    to_state, created_at
  ) VALUES (
    lower(hex(randomblob(16))), NEW.profile_definition_id, NEW.release_version,
    NEW.created_by_user_id, 'draft_created', NEW.lifecycle_state, NEW.created_at
  );
END;

CREATE TRIGGER tool_profile_release_lifecycle_audit
AFTER UPDATE OF lifecycle_state ON tool_profile_releases
WHEN OLD.lifecycle_state IS NOT NEW.lifecycle_state
BEGIN
  INSERT INTO tool_profile_release_audit (
    id, profile_definition_id, release_version, actor_user_id, action,
    from_state, to_state, reason, created_at
  ) VALUES (
    lower(hex(randomblob(16))), NEW.profile_definition_id, NEW.release_version,
    NEW.updated_by_user_id,
    CASE NEW.lifecycle_state
      WHEN 'testing' THEN 'published_for_testing'
      WHEN 'beta' THEN 'promoted_to_beta'
      WHEN 'stable' THEN 'promoted_to_stable'
      WHEN 'retired' THEN 'retired'
      WHEN 'revoked' THEN 'revoked'
    END,
    OLD.lifecycle_state, NEW.lifecycle_state, NEW.lifecycle_reason, NEW.updated_at
  );
END;

CREATE TRIGGER tool_profile_channel_target_valid_insert
BEFORE INSERT ON tool_profile_channel_pointers
WHEN NOT EXISTS (
  SELECT 1 FROM tool_profile_releases release
   WHERE release.profile_definition_id = NEW.profile_definition_id
     AND release.release_version = NEW.release_version
     AND release.published_at IS NOT NULL
     AND release.lifecycle_state = NEW.channel
)
BEGIN
  SELECT RAISE(ABORT, 'channel pointer must target an eligible published release');
END;

CREATE TRIGGER tool_profile_channel_target_valid_update
BEFORE UPDATE OF profile_definition_id, channel, release_version
ON tool_profile_channel_pointers
WHEN NOT EXISTS (
  SELECT 1 FROM tool_profile_releases release
   WHERE release.profile_definition_id = NEW.profile_definition_id
     AND release.release_version = NEW.release_version
     AND release.published_at IS NOT NULL
     AND release.lifecycle_state = NEW.channel
)
BEGIN
  SELECT RAISE(ABORT, 'channel pointer must target an eligible published release');
END;

CREATE TRIGGER tool_profile_channel_insert_audit
AFTER INSERT ON tool_profile_channel_pointers
BEGIN
  INSERT INTO tool_profile_release_audit (
    id, profile_definition_id, release_version, actor_user_id, action,
    channel, created_at
  ) VALUES (
    lower(hex(randomblob(16))), NEW.profile_definition_id, NEW.release_version,
    NEW.modified_by_user_id, 'channel_promoted', NEW.channel, NEW.updated_at
  );
END;

CREATE TRIGGER tool_profile_channel_update_audit
AFTER UPDATE OF release_version ON tool_profile_channel_pointers
WHEN OLD.release_version IS NOT NEW.release_version
BEGIN
  INSERT INTO tool_profile_release_audit (
    id, profile_definition_id, release_version, actor_user_id, action,
    previous_release_version, channel, created_at
  ) VALUES (
    lower(hex(randomblob(16))), NEW.profile_definition_id, NEW.release_version,
    NEW.modified_by_user_id,
    CASE WHEN NEW.channel = 'stable' AND NEW.release_version < OLD.release_version
      THEN 'stable_rollback' ELSE 'channel_promoted' END,
    OLD.release_version, NEW.channel, NEW.updated_at
  );
END;

CREATE TRIGGER tool_profile_channel_delete_audit
AFTER DELETE ON tool_profile_channel_pointers
BEGIN
  INSERT INTO tool_profile_release_audit (
    id, profile_definition_id, release_version, actor_user_id, action,
    previous_release_version, channel, created_at
  ) VALUES (
    lower(hex(randomblob(16))), OLD.profile_definition_id, OLD.release_version,
    OLD.modified_by_user_id, 'channel_cleared', OLD.release_version,
    OLD.channel, datetime('now')
  );
END;

CREATE TRIGGER tool_profile_release_clear_revoked_channels
AFTER UPDATE OF lifecycle_state ON tool_profile_releases
WHEN NEW.lifecycle_state IN ('retired', 'revoked')
BEGIN
  DELETE FROM tool_profile_channel_pointers
   WHERE profile_definition_id = NEW.profile_definition_id
     AND release_version = NEW.release_version;
END;

INSERT INTO worker_catalog (
  worker_type_id, display_name, description, lifecycle_state, created_at, updated_at
) VALUES
  ('chatgpt', 'ChatGPT', 'Logical Worker implemented by approved local tools.', 'active', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z'),
  ('gemini', 'Gemini', 'Logical Worker implemented by approved local tools.', 'active', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');

INSERT INTO tool_profile_definitions (
  profile_definition_id, worker_type_id, display_name, provider_tool_name,
  engine_family, schema_version, lifecycle_state, created_at, updated_at
) VALUES
  ('chatgpt-codex', 'chatgpt', 'ChatGPT Codex', 'codex', 'cli', 1, 'active', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z'),
  ('gemini-antigravity', 'gemini', 'Gemini Antigravity', 'agy', 'cli', 1, 'active', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');
