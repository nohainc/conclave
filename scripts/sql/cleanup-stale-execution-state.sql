-- Clears execution state orphaned by cancelled/failed Work Requests in a
-- LOCAL development database: active Thread leases, never-launched
-- assignments, and Work Requests stuck in `queued` behind them.
-- Safe to re-run. Apply with scripts/cleanup-local-stale-execution.sh.

UPDATE thread_runtime_leases
   SET status = 'released', released_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
 WHERE status = 'active'
   AND work_request_id IN (
     SELECT id FROM work_requests
      WHERE status IN ('cancelled', 'failed', 'completed'));

UPDATE worker_assignments
   SET status = 'cancelled', updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
 WHERE status = 'created'
   AND dispatched_at IS NULL
   AND task_id IN (
     SELECT wt.id FROM workflow_tasks wt
       JOIN work_requests wr ON wr.id = wt.work_request_id
      WHERE wr.status IN ('cancelled', 'failed', 'completed'));

-- Work Requests that are still `queued` while their Thread has no live lease
-- and were created more than 5 minutes ago never started; cancel them.
UPDATE work_requests
   SET status = 'cancelled', updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
 WHERE status = 'queued'
   AND created_at < strftime('%Y-%m-%dT%H:%M:%fZ','now','-5 minutes');
UPDATE runs
   SET status = 'cancelled', finished_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'),
       updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
 WHERE status IN ('created', 'running')
   AND work_request_id IN (SELECT id FROM work_requests WHERE status = 'cancelled');
UPDATE workflow_tasks
   SET status = 'cancelled', finished_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'),
       updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
 WHERE status IN ('queued', 'waiting', 'running')
   AND work_request_id IN (SELECT id FROM work_requests WHERE status = 'cancelled');
