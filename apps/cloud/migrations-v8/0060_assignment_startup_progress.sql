-- Phase 5 (V9): local startup progress of an accepted assignment, reported by
-- the Service with `assignment.startup`. Evidence only: it never changes the
-- assignment status or any deadline. `startup_stage` is the furthest stage the
-- Service has reported (worker_resolved .. engine_initialized); provider start
-- is still recorded through `assignment.start.ack` / `running_at`.
ALTER TABLE worker_assignments ADD COLUMN startup_stage TEXT;
ALTER TABLE worker_assignments ADD COLUMN startup_stage_at TEXT;
ALTER TABLE worker_assignments ADD COLUMN startup_detail_json TEXT;
