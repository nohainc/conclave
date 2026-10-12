-- Existing databases may already have applied the Gemini starter migrations.
-- Keep the authoring starter aligned so the next signed release can carry the
-- provider's explicit full-local-access invocation mapping.
UPDATE tool_profile_starter_templates
SET profile_json = json_set(
      profile_json,
      '$.sandbox.mappings.full_access',
      json_array('--dangerously-skip-permissions')
    ),
    updated_at = '2026-10-12T00:00:00Z'
WHERE profile_definition_id = 'gemini-antigravity'
  AND json_valid(profile_json) = 1
  AND (
    json_extract(profile_json, '$.sandbox.mappings.full_access') IS NULL
    OR json_array_length(
      json_extract(profile_json, '$.sandbox.mappings.full_access')
    ) = 0
  );
