-- Thread-scoped fencing counter that outlives Work history.
--
-- Cloud issued the next Thread lease token as MAX(fencing_token) over the
-- Thread's lease rows. Leases are deleted with their Work Requests (cascade),
-- so "Clear Work history" restarted the counter at 1 while the Workspace kept
-- the previous per-Thread fence. The Workspace then rejected the new lease as
-- "stale or conflicting Space fencing token", which surfaced as a misleading
-- "Worker is not ready".
--
-- The counter now lives on the Thread, is only ever increased, and is never
-- touched by clearing Work history.
--
-- Existing Threads start from their highest recorded token. A Thread whose
-- history was cleared before this migration may still be behind the fence its
-- Workspace recorded; the Workspace "Reset slots" action clears that once.

ALTER TABLE threads ADD COLUMN lease_fence_counter INTEGER NOT NULL DEFAULT 0
  CHECK (lease_fence_counter >= 0);

UPDATE threads
   SET lease_fence_counter = COALESCE(
     (SELECT MAX(l.fencing_token)
        FROM thread_runtime_leases l
       WHERE l.thread_id = threads.id),
     0);
