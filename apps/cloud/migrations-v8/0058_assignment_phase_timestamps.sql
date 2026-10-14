-- Phase 3 (V9): each assignment deadline starts at its own event instead of
-- at assignment creation. These columns record when the Gateway queued the
-- command, when the Service admitted it, and when the provider started.
-- Rows that predate this migration have NULLs; deadline evaluation falls back
-- to updated_at/created_at for them.
ALTER TABLE worker_assignments ADD COLUMN dispatched_at TEXT;
ALTER TABLE worker_assignments ADD COLUMN acknowledged_at TEXT;
ALTER TABLE worker_assignments ADD COLUMN running_at TEXT;
