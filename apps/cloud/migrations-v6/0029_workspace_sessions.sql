-- Track each active Workspace runtime connection for presence and heartbeat state.
CREATE TABLE workspace_sessions (
  id TEXT PRIMARY KEY,

  workspace_id TEXT NOT NULL
    REFERENCES execution_workspaces(id)
    ON DELETE CASCADE,

  runtime_identity_id TEXT NOT NULL
    REFERENCES workspace_runtime_identities(id)
    ON DELETE CASCADE,

  client_version TEXT NOT NULL,
  protocol_version TEXT NOT NULL,

  ip_address TEXT,

  connected_at TEXT NOT NULL,
  last_heartbeat_at TEXT NOT NULL,
  disconnected_at TEXT
);

CREATE INDEX idx_workspace_sessions_workspace
  ON workspace_sessions(workspace_id);
