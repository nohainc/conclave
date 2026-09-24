-- V5-15: accounting dimensions and separated execution audit history.
-- This is intentionally additive to the clean v5 baseline. It does not
-- recreate collaborative Workspace tenancy or add compatibility views.

ALTER TABLE usage ADD COLUMN execution_workspace_id TEXT REFERENCES execution_workspaces(id) ON DELETE RESTRICT;
ALTER TABLE usage ADD COLUMN workspace_owner_user_id TEXT REFERENCES users(id) ON DELETE RESTRICT;
ALTER TABLE usage ADD COLUMN account_owner_user_id TEXT REFERENCES users(id) ON DELETE SET NULL;

CREATE INDEX idx_usage_project_recorded ON usage(project_id, recorded_at);
CREATE INDEX idx_usage_execution_workspace ON usage(execution_workspace_id, recorded_at);
CREATE INDEX idx_usage_requester ON usage(requester_user_id, recorded_at);
CREATE INDEX idx_usage_account ON usage(account_id, recorded_at);
CREATE UNIQUE INDEX idx_usage_assignment_once
  ON usage(assignment_id)
  WHERE assignment_id IS NOT NULL;

CREATE INDEX idx_budgets_project_scope ON budgets(project_id, status);
CREATE INDEX idx_budgets_run_scope ON budgets(run_id, status);
CREATE INDEX idx_budgets_account_scope ON budgets(account_id, status);

CREATE TABLE execution_workspace_audit_log (
  id TEXT PRIMARY KEY,
  execution_workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  workspace_owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  actor_type TEXT NOT NULL CHECK (actor_type IN ('user', 'workspace_runtime', 'worker', 'system')),
  actor_id TEXT NOT NULL,
  action TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  details_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);
CREATE INDEX idx_execution_workspace_audit_workspace
  ON execution_workspace_audit_log(execution_workspace_id, created_at);
CREATE INDEX idx_execution_workspace_audit_owner
  ON execution_workspace_audit_log(workspace_owner_user_id, created_at);
