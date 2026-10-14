-- Phase 6 (V9): durable terminal notification to the Cloud Workflow.
--
-- The assignment row in D1 stays the only authority for the outcome. When an
-- assignment reaches a terminal status Cloud sends an `assignment-terminal`
-- event to the Workflow instance that owns the run. `workflow_signaled_at`
-- records that the event was accepted by the Workflow; a terminal row where it
-- is still NULL is the outbox that the recovery sweep retries. A lost or
-- failed signal therefore never changes the outcome, only how soon the
-- Workflow notices it.
ALTER TABLE worker_assignments ADD COLUMN workflow_signaled_at TEXT;
ALTER TABLE worker_assignments ADD COLUMN workflow_signal_attempts INTEGER NOT NULL DEFAULT 0;

CREATE INDEX idx_worker_assignments_unsignaled_terminal
  ON worker_assignments(updated_at)
  WHERE workflow_signaled_at IS NULL
    AND status IN ('completed', 'failed', 'cancelled', 'timed_out');
