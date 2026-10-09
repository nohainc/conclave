-- Workspace attachment is an explicit Workspace grant, not a delegated
-- Space member permission. Remove the obsolete key from persisted snapshots.
UPDATE spaces
SET settings_json = json_set(
  settings_json,
  '$.memberPermissions',
  COALESCE((
    SELECT json_group_object(key, json_remove(value, '$.attachWorkspace'))
    FROM json_each(json_extract(spaces.settings_json, '$.memberPermissions'))
  ), '{}')
)
WHERE json_type(settings_json, '$.memberPermissions') = 'object';

UPDATE spaces
SET settings_json = json_set(
  settings_json,
  '$.invitationPermissions',
  COALESCE((
    SELECT json_group_object(key, json_remove(value, '$.attachWorkspace'))
    FROM json_each(json_extract(spaces.settings_json, '$.invitationPermissions'))
  ), '{}')
)
WHERE json_type(settings_json, '$.invitationPermissions') = 'object';
