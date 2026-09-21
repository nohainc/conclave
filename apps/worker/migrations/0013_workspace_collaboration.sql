-- V2-21: workspace invitations and membership lifecycle.
ALTER TABLE workspace_memberships ADD COLUMN status TEXT NOT NULL DEFAULT 'active';
CREATE INDEX IF NOT EXISTS idx_workspace_memberships_status
  ON workspace_memberships(workspace_id, status);

CREATE TABLE IF NOT EXISTS workspace_invitations (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  project_id TEXT REFERENCES projects(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('admin', 'member', 'viewer')),
  token_hash TEXT NOT NULL UNIQUE,
  invited_by_user_id TEXT NOT NULL REFERENCES users(id),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'expired', 'revoked')),
  expires_at TEXT NOT NULL,
  accepted_by_user_id TEXT REFERENCES users(id),
  accepted_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_workspace_invitations_workspace
  ON workspace_invitations(workspace_id, status);
CREATE INDEX IF NOT EXISTS idx_workspace_invitations_email
  ON workspace_invitations(email, status);
CREATE INDEX IF NOT EXISTS idx_workspace_invitations_project
  ON workspace_invitations(project_id, status);
