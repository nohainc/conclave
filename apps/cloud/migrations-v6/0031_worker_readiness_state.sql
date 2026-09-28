-- Workspace-owned readiness detail. The existing status column remains the
-- coarse scheduling gate; this projection is safe operational metadata.
ALTER TABLE workspace_worker_inventory
  ADD COLUMN readiness_state TEXT NOT NULL DEFAULT 'test_failed'
  CHECK (readiness_state IN (
    'ready', 'not_installed', 'sign_in_required', 'unsupported_cli_version',
    'adapter_unavailable', 'disabled', 'test_failed'
  ));

UPDATE workspace_worker_inventory
SET readiness_state = CASE status
  WHEN 'ready' THEN 'ready'
  WHEN 'disabled' THEN 'disabled'
  WHEN 'removed' THEN 'disabled'
  ELSE 'test_failed'
END;
