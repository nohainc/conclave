-- Complete the v6 Workspace Project Grant policy contract.
-- These fields are consumed by the grant API and scheduler but were omitted
-- from the initial v6 execution-foundation table.
ALTER TABLE workspace_project_grants
  ADD COLUMN allowed_worker_capabilities_json TEXT NOT NULL DEFAULT '[]';

ALTER TABLE workspace_project_grants
  ADD COLUMN network_policy_json TEXT NOT NULL DEFAULT '{"mode":"deny_all","allowedHosts":[]}';

ALTER TABLE workspace_project_grants
  ADD COLUMN concurrency_json TEXT NOT NULL DEFAULT '{"maxConcurrentAssignments":1}';

ALTER TABLE workspace_project_grants
  ADD COLUMN requires_step_up INTEGER NOT NULL DEFAULT 0 CHECK (requires_step_up IN (0, 1));
