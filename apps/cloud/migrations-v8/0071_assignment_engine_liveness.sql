-- Service-reported process liveness for running assignments. The Service lists
-- the assignments whose Engine process it can still see on each heartbeat;
-- Cloud counts consecutive reports that omit a running assignment.
ALTER TABLE worker_assignments ADD COLUMN engine_alive_at TEXT;
ALTER TABLE worker_assignments ADD COLUMN engine_missing_reports INTEGER NOT NULL DEFAULT 0;
