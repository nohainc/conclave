-- Additive guard within the fresh v8 baseline. Existing evidence is retained;
-- missing historical labels/defaults are never filled from today's catalog.
CREATE TRIGGER trg_assignment_execution_selection_immutable
BEFORE UPDATE OF permission_snapshot_json, model, worker_type_id, workspace_worker_id ON worker_assignments
WHEN NEW.model IS NOT OLD.model
  OR NEW.worker_type_id IS NOT OLD.worker_type_id
  OR NEW.workspace_worker_id IS NOT OLD.workspace_worker_id
  OR json_extract(NEW.permission_snapshot_json, '$.executionSelection') IS NOT json_extract(OLD.permission_snapshot_json, '$.executionSelection')
  OR json_extract(NEW.permission_snapshot_json, '$.workerDisplayName') IS NOT json_extract(OLD.permission_snapshot_json, '$.workerDisplayName')
  OR json_extract(NEW.permission_snapshot_json, '$.reasoningEffort') IS NOT json_extract(OLD.permission_snapshot_json, '$.reasoningEffort')
  OR json_extract(NEW.permission_snapshot_json, '$.profileDefinitionId') IS NOT json_extract(OLD.permission_snapshot_json, '$.profileDefinitionId')
  OR json_extract(NEW.permission_snapshot_json, '$.profileReleaseVersion') IS NOT json_extract(OLD.permission_snapshot_json, '$.profileReleaseVersion')
BEGIN
  SELECT RAISE(ABORT, 'Assignment execution selection is immutable');
END;
