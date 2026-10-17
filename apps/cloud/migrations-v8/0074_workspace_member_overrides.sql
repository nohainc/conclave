-- Per-person replacement of a Workspace's default member access policy
-- (ADR-020). No row means the person follows the Workspace default.
CREATE TABLE workspace_member_overrides (
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  policy_json TEXT NOT NULL CHECK (json_valid(policy_json)),
  updated_at TEXT NOT NULL,
  PRIMARY KEY (workspace_id, user_id)
);
