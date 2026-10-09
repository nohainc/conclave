-- The default workflow is a scope-level preference, separate from the
-- per-workflow execution configuration rows.
CREATE TABLE user_workflow_defaults (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  workflow_id TEXT NOT NULL DEFAULT 'chat',
  updated_at TEXT NOT NULL
);

CREATE TABLE space_workflow_defaults (
  space_id TEXT PRIMARY KEY REFERENCES spaces(id) ON DELETE CASCADE,
  workflow_id TEXT NOT NULL DEFAULT 'chat',
  updated_at TEXT NOT NULL
);

-- Chat is always available and cannot remain disabled after the migration
-- that converted the old Space-wide Work flag into per-workflow rows.
UPDATE user_workflow_configurations
   SET configuration_json = json_set(configuration_json, '$.enabled', json('true'))
 WHERE workflow_id = 'chat';
UPDATE space_workflow_configurations
   SET configuration_json = json_set(configuration_json, '$.enabled', json('true'))
 WHERE workflow_id = 'chat';
