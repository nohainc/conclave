-- V6 Workspace-owner execution and security audit.
CREATE TABLE workspace_audit_log (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  actor_type TEXT NOT NULL CHECK (actor_type IN ('user', 'workspace', 'worker', 'system')),
  actor_id TEXT NOT NULL,
  action TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  details_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);

CREATE INDEX idx_v6_workspace_audit_time
  ON workspace_audit_log(workspace_id, created_at DESC);
