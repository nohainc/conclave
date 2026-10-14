-- Add work_session_generation to threads table.
--
-- This column enables fresh Work provider sessions after clearing Work history.
-- When incremented, it changes the Work session key, forcing a new provider
-- session with no resume arguments on the next Work Request.
--
-- The default value of 0 ensures existing threads use the legacy session key,
-- so the clear operation is safe and backwards-compatible.

ALTER TABLE threads ADD COLUMN work_session_generation INTEGER NOT NULL DEFAULT 0;
