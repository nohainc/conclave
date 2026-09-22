-- Versioned extension/template records use a physical row ID so multiple
-- versions of one logical extension can coexist for one workspace.

CREATE TABLE extensions (
  row_id TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  extension_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('provider', 'agent', 'tool', 'ci', 'human')),
  name TEXT NOT NULL,
  version TEXT NOT NULL,
  manifest_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL CHECK (status IN ('active', 'disabled', 'pending_review')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (organization_id, extension_id, version)
);
CREATE INDEX idx_extensions_organization ON extensions(organization_id);

CREATE TABLE workflow_templates (
  row_id TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  template_id TEXT NOT NULL,
  name TEXT NOT NULL,
  version INTEGER NOT NULL,
  template_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL CHECK (status IN ('draft', 'active', 'archived')),
  created_by_user_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (organization_id, template_id, version)
);
CREATE INDEX idx_workflow_templates_organization
  ON workflow_templates(organization_id);
