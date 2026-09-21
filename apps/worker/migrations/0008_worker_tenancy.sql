-- Worker registry entries are organization-owned resources.
ALTER TABLE workers ADD COLUMN organization_id TEXT REFERENCES organizations(id);
CREATE INDEX IF NOT EXISTS idx_workers_organization ON workers(organization_id);
