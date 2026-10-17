-- Workspace invitations and Person Grants (ADR-020). Accepting an invitation
-- creates a grant and nothing else; it never creates a people relationship.
CREATE TABLE workspace_invitations (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  invited_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (
    status IN ('pending', 'accepted', 'expired', 'revoked')
  ),
  expires_at TEXT NOT NULL,
  accepted_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  accepted_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_workspace_invitations_pending_email
  ON workspace_invitations(workspace_id, LOWER(email)) WHERE status = 'pending';
CREATE INDEX idx_workspace_invitations_email ON workspace_invitations(LOWER(email), status);

CREATE TABLE workspace_person_grants (
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  granted_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (workspace_id, user_id)
);
