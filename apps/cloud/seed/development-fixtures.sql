-- Development/test-only fixture identities. Never apply this seed in production.
INSERT OR IGNORE INTO worker_catalog (
  worker_type_id, display_name, description, lifecycle_state,
  engine_family, visibility_state, release_stage, capabilities_json,
  sort_order, created_at, updated_at
) VALUES
  ('fixture-worker', 'Fixture CLI', 'Development-only CLI Worker used to validate generic Profile integrations.', 'active',
   'cli', 'visible', 'testing', '["text"]', 5,
   '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');

INSERT OR IGNORE INTO tool_profile_definitions (
  profile_definition_id, worker_type_id, display_name, provider_tool_name,
  engine_family, schema_version, lifecycle_state, created_at, updated_at
) VALUES
  ('fixture-cli', 'fixture-worker', 'Fixture CLI', 'Fixture CLI', 'cli', 1, 'active',
   '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z');
