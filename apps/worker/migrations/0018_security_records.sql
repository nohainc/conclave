CREATE TABLE credentials (
  id TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  key_id TEXT NOT NULL,
  algorithm TEXT NOT NULL CHECK (algorithm = 'AES-GCM'),
  iv TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT,
  UNIQUE (organization_id, provider)
);
CREATE INDEX idx_credentials_organization ON credentials(organization_id);

CREATE TABLE retention_policies (
  id TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  audit_days INTEGER NOT NULL,
  artifact_days INTEGER NOT NULL,
  usage_days INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (organization_id)
);

CREATE TABLE human_approvals (
  id TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
  requested_by_user_id TEXT NOT NULL REFERENCES users(id),
  decided_by_user_id TEXT REFERENCES users(id),
  prompt TEXT NOT NULL,
  decision TEXT NOT NULL CHECK (decision IN ('pending', 'approved', 'rejected')),
  requested_at TEXT NOT NULL,
  decided_at TEXT
);
CREATE INDEX idx_human_approvals_organization ON human_approvals(organization_id);
CREATE INDEX idx_human_approvals_run ON human_approvals(run_id);
