-- Invitation management is an owner-only Space capability. Remove the
-- obsolete member-level right from persisted permission snapshots while
-- preserving every other configured right.
UPDATE spaces
SET settings_json = json_set(
  settings_json,
  '$.memberPermissions',
  COALESCE((
    SELECT json_group_object(key, json_remove(value, '$.inviteMembers'))
    FROM json_each(json_extract(spaces.settings_json, '$.memberPermissions'))
  ), '{}')
)
WHERE json_type(settings_json, '$.memberPermissions') = 'object';

UPDATE spaces
SET settings_json = json_set(
  settings_json,
  '$.invitationPermissions',
  COALESCE((
    SELECT json_group_object(key, json_remove(value, '$.inviteMembers'))
    FROM json_each(json_extract(spaces.settings_json, '$.invitationPermissions'))
  ), '{}')
)
WHERE json_type(settings_json, '$.invitationPermissions') = 'object';
