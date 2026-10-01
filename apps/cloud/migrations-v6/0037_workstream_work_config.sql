-- Replace open-ended role usage policy with the fixed Work v1 configuration.
-- Development data is intentionally reset; Workstreams use the canonical
-- default Workflow and are configured again with direct/StepKind bindings.
DROP TABLE workstream_worker_usage_policies;

CREATE TABLE workstream_work_configs (
  workstream_id TEXT PRIMARY KEY REFERENCES workstreams(id) ON DELETE CASCADE,
  config_json TEXT NOT NULL DEFAULT '{"defaultWorkflowId":"full_cycle","bindings":{}}',
  updated_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  updated_at TEXT NOT NULL
);
