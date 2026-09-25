-- Phase 7: machine information is runtime-reported, not Workspace configuration.
-- Keep runtime facts in a separate one-to-one table so the logical Workspace
-- identity remains independent from the current machine installation.
CREATE TABLE workspace_runtime_facts (
  workspace_id TEXT PRIMARY KEY REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  platform TEXT,
  architecture TEXT,
  hostname TEXT,
  app_version TEXT,
  runtime_capabilities_json TEXT NOT NULL DEFAULT '[]',
  updated_at TEXT NOT NULL
);
