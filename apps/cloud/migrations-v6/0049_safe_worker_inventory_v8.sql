-- Replace provider Worker package version evidence with generic Engine and
-- immutable Tool Profile release identity. Assignment history remains intact.
ALTER TABLE workspace_worker_inventory ADD COLUMN engine_version TEXT;
ALTER TABLE workspace_worker_inventory ADD COLUMN profile_definition_id TEXT;
ALTER TABLE workspace_worker_inventory ADD COLUMN profile_release_version INTEGER
  CHECK (profile_release_version IS NULL OR profile_release_version > 0);
ALTER TABLE workspace_worker_inventory DROP COLUMN worker_runtime_version;
ALTER TABLE worker_assignments RENAME COLUMN worker_version TO engine_version;
