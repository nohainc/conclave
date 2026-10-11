-- Workspace-owned model discovery metadata; published signed Profiles authorize its use.
ALTER TABLE workspace_worker_inventory ADD COLUMN model_catalog_json TEXT CHECK (model_catalog_json IS NULL OR json_valid(model_catalog_json));
