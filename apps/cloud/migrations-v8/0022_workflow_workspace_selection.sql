-- Workflow execution selects one Workspace per user/Space scope.
CREATE TABLE user_workflow_settings (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  workspace_id TEXT REFERENCES execution_workspaces(id) ON DELETE SET NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE space_workflow_settings (
  space_id TEXT PRIMARY KEY REFERENCES spaces(id) ON DELETE CASCADE,
  workspace_id TEXT REFERENCES execution_workspaces(id) ON DELETE SET NULL,
  updated_at TEXT NOT NULL
);
-- Preserve existing denials as per-workflow enabled flags before removing the toggle.
INSERT INTO space_workflow_configurations(space_id,workflow_id,schema_version,configuration_json,updated_at)
SELECT s.id, w.id, 1, json_object('schemaVersion',1,'workflowId',w.id,'enabled',json('false'),'defaults',json('{}'),'stepOverrides',json('{}')), s.updated_at
FROM spaces s CROSS JOIN (SELECT 'direct' AS id UNION ALL SELECT 'research' UNION ALL SELECT 'plan_implement' UNION ALL SELECT 'implement_verify' UNION ALL SELECT 'full_cycle') w
WHERE json_extract(s.settings_json,'$.allowWork') = 0
ON CONFLICT(space_id,workflow_id) DO UPDATE SET configuration_json=json_set(space_workflow_configurations.configuration_json,'$.enabled',json('false'));
-- Workflow enabled flags now replace the removed Space-wide Work toggle.
UPDATE spaces SET settings_json = json_remove(settings_json, '$.allowWork');
