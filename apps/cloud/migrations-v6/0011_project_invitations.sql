-- Conclave Architecture v6 - Project Invitations and Audit Log for collaboration.
CREATE TABLE IF NOT EXISTS project_invitations (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('collaborator', 'viewer')),
  token_hash TEXT NOT NULL UNIQUE,
  invited_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'expired', 'revoked')),
  expires_at TEXT NOT NULL,
  accepted_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  accepted_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_v6_project_invitations_project ON project_invitations(project_id, status);

CREATE TABLE IF NOT EXISTS project_audit_log (
  id TEXT PRIMARY KEY,
  project_id TEXT REFERENCES projects(id) ON DELETE CASCADE,
  actor_type TEXT NOT NULL CHECK (actor_type IN ('user', 'workspace_runtime', 'worker', 'system')),
  actor_id TEXT NOT NULL,
  action TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  details_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_v6_project_audit_log_project ON project_audit_log(project_id, created_at);
