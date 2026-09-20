-- Phase 13: tenancy, authorization, encrypted credentials, audit, budgets, and retention.
-- Credential plaintext and encryption keys must never be stored in D1.
CREATE TABLE IF NOT EXISTS organizations (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active', 'suspended')),
  plan TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS organization_memberships (
  organization_id TEXT NOT NULL REFERENCES organizations(id),
  user_id TEXT NOT NULL,
  role TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active', 'invited', 'suspended')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (organization_id, user_id)
);

ALTER TABLE projects ADD COLUMN organization_id TEXT REFERENCES organizations(id);
CREATE INDEX IF NOT EXISTS idx_projects_organization ON projects(organization_id);

CREATE TABLE IF NOT EXISTS project_memberships (
  project_id TEXT NOT NULL REFERENCES projects(id),
  user_id TEXT NOT NULL,
  role TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (project_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_project_memberships_user ON project_memberships(user_id);

CREATE TABLE IF NOT EXISTS audit_log (
  id TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL REFERENCES organizations(id),
  actor_user_id TEXT,
  action TEXT NOT NULL,
  resource_type TEXT NOT NULL,
  resource_id TEXT,
  outcome TEXT NOT NULL CHECK (outcome IN ('success', 'denied', 'failure')),
  metadata_json TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  retention_until TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_log_org_time ON audit_log(organization_id, occurred_at);

CREATE TABLE IF NOT EXISTS encrypted_credentials (
  id TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL REFERENCES organizations(id),
  provider TEXT NOT NULL,
  key_id TEXT NOT NULL,
  algorithm TEXT NOT NULL CHECK (algorithm = 'AES-GCM'),
  iv TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT,
  UNIQUE (organization_id, provider)
);

CREATE TABLE IF NOT EXISTS budgets (
  id TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL REFERENCES organizations(id),
  project_id TEXT REFERENCES projects(id),
  run_id TEXT REFERENCES runs(id),
  max_input_tokens INTEGER,
  max_output_tokens INTEGER,
  max_cost_micros INTEGER,
  used_input_tokens INTEGER NOT NULL DEFAULT 0,
  used_output_tokens INTEGER NOT NULL DEFAULT 0,
  used_cost_micros INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL CHECK (status IN ('active', 'exhausted', 'disabled')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_budgets_scope ON budgets(organization_id, project_id, run_id);

CREATE TABLE IF NOT EXISTS rate_limit_buckets (
  organization_id TEXT NOT NULL REFERENCES organizations(id),
  bucket_key TEXT NOT NULL,
  window_started_at TEXT NOT NULL,
  request_count INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (organization_id, bucket_key, window_started_at)
);

CREATE TABLE IF NOT EXISTS retention_policies (
  organization_id TEXT PRIMARY KEY REFERENCES organizations(id),
  audit_days INTEGER NOT NULL,
  artifact_days INTEGER NOT NULL,
  usage_days INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
