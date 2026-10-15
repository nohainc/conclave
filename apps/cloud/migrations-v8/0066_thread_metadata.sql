-- Thread metadata: Cloud-backed presentation state that follows the Thread
-- across browsers (active tab, selected workflow, Worker, model, effort).
--
-- The column holds a JSON object. It is validated by the Thread route and is
-- never used for authorization, scheduling, or execution decisions.

ALTER TABLE threads ADD COLUMN metadata_json TEXT NOT NULL DEFAULT '{}';
