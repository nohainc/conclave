-- Workspace-level parallel execution slots.
--
-- The Workspace reports one shared slot total (the "Parallel executions"
-- setting). Until now Cloud only saw it replicated on every Worker record as
-- `workspace_worker_inventory.local_concurrency_limit`. Store it once on the
-- Workspace so scheduling reads a single authoritative number. NULL means the
-- Workspace has not reported it yet (an older Service); the scheduler then
-- falls back to the per-Worker value. The per-Worker column is kept for
-- rollout compatibility and is no longer a user-facing concept.
ALTER TABLE execution_workspaces ADD COLUMN parallel_slots INTEGER
  CHECK (parallel_slots IS NULL OR parallel_slots BETWEEN 1 AND 1024);

-- Backfill from the values the Service already reported (they are identical on
-- every Worker of a Workspace).
UPDATE execution_workspaces
   SET parallel_slots = (
     SELECT MAX(i.local_concurrency_limit)
       FROM workspace_worker_inventory i
      WHERE i.workspace_id = execution_workspaces.id
   )
 WHERE parallel_slots IS NULL
   AND EXISTS (
     SELECT 1 FROM workspace_worker_inventory i
      WHERE i.workspace_id = execution_workspaces.id
   );
