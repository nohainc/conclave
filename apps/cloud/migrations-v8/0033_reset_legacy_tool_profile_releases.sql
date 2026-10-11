-- Development cutover: Tool Profile releases created before the capability
-- metadata removal are retired from the database instead of being kept behind
-- a compatibility parser. This is intentionally destructive and must not be
-- used as a production-preserving migration.

DROP TRIGGER IF EXISTS tool_profile_published_release_no_delete;
DROP TRIGGER IF EXISTS tool_profile_acceptance_evidence_no_delete;
DROP TRIGGER IF EXISTS tool_profile_local_qualification_no_delete;

-- Clear references and evidence before deleting the releases they reference.
DELETE FROM tool_profile_channel_pointers;
DELETE FROM workspace_tool_profile_channels;
DELETE FROM tool_profile_acceptance_evidence;
DELETE FROM tool_profile_local_qualification_evidence;
DELETE FROM tool_profile_release_audit;
DELETE FROM tool_profile_releases;

-- Existing inventory rows must be requalified against a newly authored
-- release. Keep the local worker identity, but remove stale profile claims.
UPDATE workspace_worker_inventory
SET profile_definition_id = NULL,
    profile_release_version = NULL,
    provider_tool_version = NULL,
    readiness_state = 'not_probed',
    readiness_issue_code = NULL;

-- Starter templates are authoring inputs, not releases. Normalize them too so
-- a newly created draft cannot inherit the retired field.
UPDATE tool_profile_starter_templates
SET profile_json = json_remove(profile_json, '$.capabilities')
WHERE json_valid(profile_json) = 1;

-- Preserve the lifecycle protections for all newly authored releases.
CREATE TRIGGER tool_profile_published_release_no_delete
BEFORE DELETE ON tool_profile_releases
WHEN OLD.published_at IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'published Tool Profile releases cannot be deleted');
END;

CREATE TRIGGER tool_profile_local_qualification_no_delete
BEFORE DELETE ON tool_profile_local_qualification_evidence
BEGIN
  SELECT RAISE(ABORT, 'Tool Profile local qualification evidence cannot be deleted');
END;

CREATE TRIGGER tool_profile_acceptance_evidence_no_delete
BEFORE DELETE ON tool_profile_acceptance_evidence
BEGIN
  SELECT RAISE(ABORT, 'Tool Profile acceptance evidence cannot be deleted');
END;
