-- Worker/Profile capability metadata is no longer part of the v8 contract.
-- The API and runtime already stopped reading or writing these fields in 0031.
-- Remove the legacy storage columns after clearing them so new databases and
-- existing databases expose the same model.
ALTER TABLE worker_catalog DROP COLUMN capabilities_json;
ALTER TABLE workspace_worker_inventory DROP COLUMN capabilities_json;
ALTER TABLE workspace_space_grants DROP COLUMN allowed_worker_capabilities_json;
