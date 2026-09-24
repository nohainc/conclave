-- V6 runtime enrollment codes belong to execution Workspaces.
-- They must not reference the removed collaborative Workspace tenant tables.
CREATE TABLE workspace_enrollments (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  created_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  expires_at TEXT NOT NULL,
  used_at TEXT,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX idx_v6_workspace_enrollments_workspace
  ON workspace_enrollments(workspace_id, created_at DESC);
