-- Profile channels are selected by Cloud per Workspace. The absence of an
-- override means stable, so ordinary Workspaces do not need a row.
CREATE TABLE workspace_tool_profile_channels (
  workspace_id TEXT PRIMARY KEY
    REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  channel TEXT NOT NULL CHECK (channel IN ('testing', 'beta', 'stable')),
  updated_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_workspace_tool_profile_channels_channel
  ON workspace_tool_profile_channels(channel);
