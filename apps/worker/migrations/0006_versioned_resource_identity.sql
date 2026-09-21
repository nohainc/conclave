-- Phase 14 correction: row identity and logical/version identity are distinct.
ALTER TABLE extensions RENAME TO extensions_v1;
CREATE TABLE extensions (
  id TEXT PRIMARY KEY,
  extension_id TEXT NOT NULL,
  organization_id TEXT NOT NULL REFERENCES organizations(id),
  kind TEXT NOT NULL CHECK (kind IN ('provider', 'agent', 'tool', 'ci', 'human')),
  name TEXT NOT NULL,
  version TEXT NOT NULL,
  manifest_json TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active', 'disabled', 'pending_review')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (organization_id, extension_id, version)
);
INSERT INTO extensions (id, extension_id, organization_id, kind, name, version, manifest_json, status, created_at, updated_at)
  SELECT id, id, organization_id, kind, name, version, manifest_json, status, created_at, updated_at FROM extensions_v1;
DROP TABLE extensions_v1;
CREATE INDEX IF NOT EXISTS idx_extensions_logical_id ON extensions(organization_id, extension_id);

ALTER TABLE workflow_templates RENAME TO workflow_templates_v1;
CREATE TABLE workflow_templates (
  id TEXT PRIMARY KEY,
  template_id TEXT NOT NULL,
  organization_id TEXT NOT NULL REFERENCES organizations(id),
  name TEXT NOT NULL,
  version INTEGER NOT NULL,
  template_json TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('draft', 'active', 'archived')),
  created_by_user_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (organization_id, template_id, version)
);
INSERT INTO workflow_templates (id, template_id, organization_id, name, version, template_json, status, created_by_user_id, created_at, updated_at)
  SELECT id, id, organization_id, name, version, template_json, status, created_by_user_id, created_at, updated_at FROM workflow_templates_v1;
DROP TABLE workflow_templates_v1;
CREATE INDEX IF NOT EXISTS idx_workflow_templates_logical_id ON workflow_templates(organization_id, template_id);
