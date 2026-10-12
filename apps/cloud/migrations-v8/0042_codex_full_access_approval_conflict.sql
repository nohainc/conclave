-- Codex rejects --ask-for-approval together with
-- --dangerously-bypass-approvals-and-sandbox. Keep the approval policy on the
-- restricted/provider-default mappings and make full_access a standalone,
-- valid unrestricted invocation.
UPDATE tool_profile_starter_templates
SET profile_json = json_set(
      json_remove(
        json_remove(profile_json, '$.execution.arguments[0]'),
        '$.execution.arguments[0]'
      ),
      '$.sandbox.mappings.restricted',
      json_array('--ask-for-approval', 'never', '--sandbox', 'workspace-write'),
      '$.sandbox.mappings.provider_default',
      json_array('--ask-for-approval', 'never', '--sandbox', 'read-only'),
      '$.sandbox.mappings.full_access',
      json_array('--dangerously-bypass-approvals-and-sandbox')
    ),
    updated_at = '2026-10-12T00:00:00Z'
WHERE profile_definition_id = 'chatgpt-codex'
  AND json_valid(profile_json) = 1
  AND json_extract(profile_json, '$.execution.arguments[0]') = '--ask-for-approval';

UPDATE tool_profile_starter_templates
SET profile_json = json_remove(
      json_remove(
        profile_json,
        '$.compatibilityOverrides[0].executionArguments[0]'
      ),
      '$.compatibilityOverrides[0].executionArguments[0]'
    ),
    updated_at = '2026-10-12T00:00:00Z'
WHERE profile_definition_id = 'chatgpt-codex'
  AND json_valid(profile_json) = 1
  AND json_extract(
    profile_json,
    '$.compatibilityOverrides[0].executionArguments[0]'
  ) = '--ask-for-approval';
