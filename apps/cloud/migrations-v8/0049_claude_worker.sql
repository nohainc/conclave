-- Register the Claude Worker in the catalog.
--
-- The Worker is a first-class catalog entry before any Profile is published,
-- matching ChatGPT and Gemini. Since V9 the Profile identity lives on
-- worker_catalog (profile_definition_id, provider_tool_name); the V8
-- tool_profile_definitions and tool_profile_starter_templates tables were
-- removed in 0044, so this migration does not write to them.
--
-- The Worker starts in the testing release stage, as the Profile Lab Create
-- Worker flow requires for new catalog entries. Profile Lab reads worker_catalog
-- directly, so the Worker is visible there immediately. No Profile is published
-- by this migration; a qualified Profile must be tested, synced and published
-- through Profile Lab.

INSERT OR IGNORE INTO worker_catalog (
  worker_type_id, display_name, description, lifecycle_state,
  engine_family, visibility_state, release_stage,
  sort_order, created_at, updated_at,
  profile_definition_id, provider_tool_name
) VALUES (
  'claude', 'Claude', 'Logical Worker implemented by approved local tools.', 'active',
  'cli', 'visible', 'testing',
  30, '2026-10-13T00:00:00Z', '2026-10-13T00:00:00Z',
  'claude-code', 'claude'
);
