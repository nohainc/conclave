CREATE TABLE connections (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  transport TEXT NOT NULL,
  provider TEXT,
  adapter_version TEXT NOT NULL,
  auth_mode TEXT NOT NULL,
  billing_mode TEXT NOT NULL,
  cost_metadata_json TEXT NOT NULL DEFAULT '{}',
  execution_environment TEXT NOT NULL CHECK (execution_environment IN ('cloud', 'local', 'ci', 'human')),
  availability TEXT NOT NULL CHECK (availability IN ('available', 'busy', 'disabled', 'offline')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_connections_workspace ON connections(workspace_id);
