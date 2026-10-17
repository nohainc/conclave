-- Workflow configuration and the default workflow belong to a Workspace. A user
-- keeps one configuration set per owned Workspace, so changing the selected
-- Workspace no longer discards the settings of the others.
ALTER TABLE user_workflow_configurations RENAME TO user_workflow_configurations_v1;
CREATE TABLE user_workflow_configurations (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  workflow_id TEXT NOT NULL,
  schema_version INTEGER NOT NULL CHECK (schema_version = 1),
  configuration_json TEXT NOT NULL CHECK (json_valid(configuration_json)),
  updated_at TEXT NOT NULL,
  PRIMARY KEY (user_id, workspace_id, workflow_id)
);
-- Existing rows described the user's selected Workspace.
INSERT INTO user_workflow_configurations(user_id,workspace_id,workflow_id,schema_version,configuration_json,updated_at)
SELECT c.user_id, s.workspace_id, c.workflow_id, c.schema_version, c.configuration_json, c.updated_at
  FROM user_workflow_configurations_v1 c
  JOIN user_workflow_settings s ON s.user_id = c.user_id AND s.workspace_id IS NOT NULL;
DROP TABLE user_workflow_configurations_v1;

ALTER TABLE user_workflow_defaults RENAME TO user_workflow_defaults_v1;
CREATE TABLE user_workflow_defaults (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  workflow_id TEXT NOT NULL DEFAULT 'chat',
  updated_at TEXT NOT NULL,
  PRIMARY KEY (user_id, workspace_id)
);
INSERT INTO user_workflow_defaults(user_id,workspace_id,workflow_id,updated_at)
SELECT d.user_id, s.workspace_id, d.workflow_id, d.updated_at
  FROM user_workflow_defaults_v1 d
  JOIN user_workflow_settings s ON s.user_id = d.user_id AND s.workspace_id IS NOT NULL;
DROP TABLE user_workflow_defaults_v1;
