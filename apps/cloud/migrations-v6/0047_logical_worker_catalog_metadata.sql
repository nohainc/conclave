ALTER TABLE worker_catalog ADD COLUMN engine_family TEXT NOT NULL DEFAULT 'cli'
  CHECK (engine_family = 'cli');
ALTER TABLE worker_catalog ADD COLUMN visibility_state TEXT NOT NULL DEFAULT 'visible'
  CHECK (visibility_state IN ('hidden', 'visible'));
ALTER TABLE worker_catalog ADD COLUMN release_stage TEXT NOT NULL DEFAULT 'stable'
  CHECK (release_stage IN ('testing', 'beta', 'stable'));
ALTER TABLE worker_catalog ADD COLUMN capabilities_json TEXT NOT NULL DEFAULT '["text"]'
  CHECK (
    json_valid(capabilities_json)
    AND json_type(capabilities_json) = 'array'
    AND length(capabilities_json) <= 2048
  );
ALTER TABLE worker_catalog ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 100
  CHECK (sort_order >= 0 AND sort_order <= 10000);

UPDATE worker_catalog
   SET capabilities_json = '["text","local_file","workstream_read","workstream_write","durable_session"]',
       sort_order = CASE worker_type_id WHEN 'chatgpt' THEN 10 WHEN 'gemini' THEN 20 ELSE sort_order END
 WHERE worker_type_id IN ('chatgpt', 'gemini');

CREATE UNIQUE INDEX idx_tool_profile_one_active_definition_per_worker
  ON tool_profile_definitions(worker_type_id)
  WHERE lifecycle_state = 'active';
