ALTER TABLE worker_assignments
  ADD COLUMN queue_wait_timeout_ms INTEGER NOT NULL DEFAULT 120000;

