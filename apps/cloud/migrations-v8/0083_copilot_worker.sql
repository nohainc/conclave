-- Register the Copilot Worker in the catalog.
--
-- Same shape as 0049_claude_worker.sql: the Worker is a catalog entry in the
-- testing release stage, implemented by the copilot-cli Profile running the
-- GitHub Copilot CLI (`copilot`) under the generic CLI Worker Engine. No
-- Profile is published by this migration; a qualified Profile must be tested,
-- synced and published through Profile Lab.

INSERT OR IGNORE INTO worker_catalog (
  worker_type_id, display_name, description, lifecycle_state,
  engine_family, visibility_state, release_stage,
  sort_order, created_at, updated_at,
  profile_definition_id, provider_tool_name
) VALUES (
  'copilot', 'Copilot', 'Logical Worker implemented by approved local tools.', 'active',
  'cli', 'visible', 'testing',
  40, '2026-10-23T00:00:00Z', '2026-10-23T00:00:00Z',
  'copilot-cli', 'copilot'
);
