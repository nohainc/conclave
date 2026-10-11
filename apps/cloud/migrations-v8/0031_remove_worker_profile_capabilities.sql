-- Worker capability metadata is no longer part of the v8 execution contract.
-- Keep the legacy columns for migration compatibility, but clear their
-- persisted values and remove the field from starter Tool Profile payloads.
UPDATE worker_catalog
SET capabilities_json = '[]';

UPDATE workspace_worker_inventory
SET capabilities_json = '[]';

UPDATE workspace_space_grants
SET allowed_worker_capabilities_json = '[]';

UPDATE tool_profile_starter_templates
SET profile_json = json_remove(profile_json, '$.capabilities')
WHERE json_valid(profile_json) = 1;
