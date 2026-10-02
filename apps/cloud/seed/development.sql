-- Optional development seed for the built-in logical Workers and Profile definitions.
-- The same canonical records are included in the v8 baseline migration.
INSERT OR IGNORE INTO worker_catalog (
  worker_type_id, display_name, description, lifecycle_state,
  engine_family, visibility_state, release_stage, capabilities_json,
  sort_order, created_at, updated_at
) VALUES
  ('chatgpt', 'ChatGPT', 'Logical Worker implemented by approved local tools.', 'active',
   'cli', 'visible', 'stable',
   '["text","local_file","workstream_read","workstream_write","durable_session"]',
   10, '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z'),
  ('gemini', 'Gemini', 'Logical Worker implemented by approved local tools.', 'active',
   'cli', 'visible', 'stable',
   '["text","local_file","workstream_read","workstream_write","durable_session"]',
   20, '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');

INSERT OR IGNORE INTO tool_profile_definitions (
  profile_definition_id, worker_type_id, display_name, provider_tool_name,
  engine_family, schema_version, lifecycle_state, created_at, updated_at
) VALUES
  ('chatgpt-codex', 'chatgpt', 'ChatGPT Codex', 'codex', 'cli', 1, 'active',
   '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z'),
  ('gemini-antigravity', 'gemini', 'Gemini Antigravity', 'agy', 'cli', 1, 'active',
   '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');
