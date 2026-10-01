-- Each submitted Work Request keeps the prompt and binding choices used by its
-- run, independent of later Project or Workstream configuration changes.
ALTER TABLE work_requests
  ADD COLUMN snapshot_json TEXT NOT NULL DEFAULT '{}';

CREATE TRIGGER trg_work_requests_snapshot_immutable
BEFORE UPDATE OF workstream_id, requested_by_user_id, mode, workflow_id,
  workflow_version, workflow_snapshot_json, snapshot_json,
  primary_workspace_id, checkout_id, input_json
ON work_requests
WHEN OLD.workstream_id IS NOT NEW.workstream_id
  OR OLD.requested_by_user_id IS NOT NEW.requested_by_user_id
  OR OLD.mode IS NOT NEW.mode
  OR OLD.workflow_id IS NOT NEW.workflow_id
  OR OLD.workflow_version IS NOT NEW.workflow_version
  OR OLD.workflow_snapshot_json IS NOT NEW.workflow_snapshot_json
  OR OLD.snapshot_json IS NOT NEW.snapshot_json
  OR OLD.primary_workspace_id IS NOT NEW.primary_workspace_id
  OR OLD.checkout_id IS NOT NEW.checkout_id
  OR OLD.input_json IS NOT NEW.input_json
BEGIN
  SELECT RAISE(ABORT, 'Work Request snapshots are immutable');
END;
