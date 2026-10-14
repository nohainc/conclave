-- Preserve the optional normalized activity metadata in durable history.
ALTER TABLE worker_activity_history ADD COLUMN duration_ms INTEGER;
ALTER TABLE worker_activity_history ADD COLUMN tool_id TEXT;
ALTER TABLE worker_activity_history ADD COLUMN tool_name TEXT;
