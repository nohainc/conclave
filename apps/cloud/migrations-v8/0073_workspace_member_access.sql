-- Optional allowlist of Workers, models and efforts that a Workspace shares
-- with invited Space members. No row means members may use whatever the
-- Workspace owner's workflow configuration selects.
CREATE TABLE workspace_member_access (
  workspace_id TEXT PRIMARY KEY REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  policy_json TEXT NOT NULL CHECK (json_valid(policy_json)),
  updated_at TEXT NOT NULL
);
