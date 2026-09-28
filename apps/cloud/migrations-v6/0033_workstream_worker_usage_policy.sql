-- AX-owned usage policy: role-to-Worker/model choices and scheduler behavior.
-- Local readiness, credentials, and execution permissions remain Workspace-owned.
CREATE TABLE workstream_worker_usage_policies (
  workstream_id TEXT PRIMARY KEY REFERENCES workstreams(id) ON DELETE CASCADE,
  policy_json TEXT NOT NULL DEFAULT '{"version":1,"fallbackPolicy":"configured_only","roles":{}}',
  updated_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  updated_at TEXT NOT NULL
);
