-- Phase 4 (V9): a connected Service is not necessarily ready to accept Work.
-- `workspace_service_readiness` records the Service-level readiness published
-- for the authenticated runtime session. It is separate from
-- `execution_workspaces.status` (connection liveness) and from Worker
-- eligibility (`workspace_worker_inventory`).
CREATE TABLE IF NOT EXISTS workspace_service_readiness (
  workspace_id TEXT PRIMARY KEY,
  runtime_identity_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  sync_generation INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL,
  ready_for_assignments INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'service',
  reason TEXT,
  updated_at TEXT NOT NULL
);

-- The complete assignment.start payload, persisted before any delivery
-- attempt so that work for a connected-but-unready Service waits in a durable
-- Cloud-side queue and is flushed unchanged when the Service becomes ready.
ALTER TABLE worker_assignments ADD COLUMN command_payload_json TEXT;
