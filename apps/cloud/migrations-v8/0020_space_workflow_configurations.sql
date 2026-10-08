-- Shared Space overrides; absent workflow rows inherit the Space owner's defaults.
CREATE TABLE space_workflow_configurations (
  space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  workflow_id TEXT NOT NULL,
  schema_version INTEGER NOT NULL CHECK (schema_version = 1),
  configuration_json TEXT NOT NULL CHECK (json_valid(configuration_json)),
  updated_at TEXT NOT NULL,
  PRIMARY KEY (space_id, workflow_id)
);
