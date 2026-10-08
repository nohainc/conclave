-- Additive v8 baseline: user preferences are independent of Spaces/Threads.
CREATE TABLE user_workflow_configurations (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  workflow_id TEXT NOT NULL,
  schema_version INTEGER NOT NULL CHECK (schema_version = 1),
  configuration_json TEXT NOT NULL CHECK (json_valid(configuration_json)),
  updated_at TEXT NOT NULL,
  PRIMARY KEY (user_id, workflow_id)
);
