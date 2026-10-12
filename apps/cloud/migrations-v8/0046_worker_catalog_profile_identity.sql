-- V9 initial-authoring metadata.
--
-- A Worker can exist before its first current Profile is published. Keep the
-- configured Profile identity on the catalog row so Profile Lab can create
-- that first local candidate without consulting removed V8 definition tables
-- or inventing provider-specific defaults.

ALTER TABLE worker_catalog ADD COLUMN profile_definition_id TEXT;
ALTER TABLE worker_catalog ADD COLUMN provider_tool_name TEXT;

-- Preserve first-party identities for installations that already passed the
-- V8 definition cleanup migration. Custom Workers must be provisioned with
-- the same metadata by their catalog owner before authoring a Profile.
UPDATE worker_catalog
   SET profile_definition_id = 'chatgpt-codex',
       provider_tool_name = 'codex'
 WHERE worker_type_id = 'chatgpt'
   AND profile_definition_id IS NULL;

UPDATE worker_catalog
   SET profile_definition_id = 'gemini-antigravity',
       provider_tool_name = 'agy'
 WHERE worker_type_id = 'gemini'
   AND profile_definition_id IS NULL;
