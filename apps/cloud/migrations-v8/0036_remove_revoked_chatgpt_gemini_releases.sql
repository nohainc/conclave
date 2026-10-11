-- Development cleanup: remove revoked ChatGPT and Gemini releases so their
-- version numbers can be authored again as fresh drafts. This intentionally
-- deletes only already-revoked releases for these two catalog Workers; active
-- releases, definitions, and releases for other Workers are preserved.
--
-- Published releases are normally immutable and undeletable. The dependent
-- audit/evidence rows must be removed first because they use RESTRICT foreign
-- keys. Inventory claims are cleared so no Workspace can retain a reference
-- to a release that no longer exists.

DROP TRIGGER IF EXISTS tool_profile_published_release_no_delete;
DROP TRIGGER IF EXISTS tool_profile_acceptance_evidence_no_delete;
DROP TRIGGER IF EXISTS tool_profile_local_qualification_no_delete;

DELETE FROM workspace_worker_inventory
 WHERE profile_definition_id IN (
   SELECT profile_definition_id
     FROM tool_profile_releases
    WHERE worker_type_id IN ('chatgpt', 'gemini')
      AND lifecycle_state = 'revoked'
 )
   AND profile_release_version IN (
     SELECT release_version
       FROM tool_profile_releases
      WHERE worker_type_id IN ('chatgpt', 'gemini')
        AND lifecycle_state = 'revoked'
        AND profile_definition_id = workspace_worker_inventory.profile_definition_id
   );

DELETE FROM tool_profile_channel_pointers
 WHERE EXISTS (
   SELECT 1
     FROM tool_profile_releases release
    WHERE release.profile_definition_id = tool_profile_channel_pointers.profile_definition_id
      AND release.release_version = tool_profile_channel_pointers.release_version
      AND release.worker_type_id IN ('chatgpt', 'gemini')
      AND release.lifecycle_state = 'revoked'
 );

DELETE FROM tool_profile_acceptance_evidence
 WHERE EXISTS (
   SELECT 1
     FROM tool_profile_releases release
    WHERE release.profile_definition_id = tool_profile_acceptance_evidence.profile_definition_id
      AND release.release_version = tool_profile_acceptance_evidence.release_version
      AND release.worker_type_id IN ('chatgpt', 'gemini')
      AND release.lifecycle_state = 'revoked'
 );

DELETE FROM tool_profile_local_qualification_evidence
 WHERE EXISTS (
   SELECT 1
     FROM tool_profile_releases release
    WHERE release.profile_definition_id = tool_profile_local_qualification_evidence.profile_definition_id
      AND release.release_version = tool_profile_local_qualification_evidence.release_version
      AND release.worker_type_id IN ('chatgpt', 'gemini')
      AND release.lifecycle_state = 'revoked'
 );

DELETE FROM tool_profile_release_audit
 WHERE EXISTS (
   SELECT 1
     FROM tool_profile_releases release
    WHERE release.profile_definition_id = tool_profile_release_audit.profile_definition_id
      AND release.release_version = tool_profile_release_audit.release_version
      AND release.worker_type_id IN ('chatgpt', 'gemini')
      AND release.lifecycle_state = 'revoked'
 );

DELETE FROM tool_profile_releases
 WHERE worker_type_id IN ('chatgpt', 'gemini')
   AND lifecycle_state = 'revoked';

CREATE TRIGGER tool_profile_published_release_no_delete
BEFORE DELETE ON tool_profile_releases
WHEN OLD.published_at IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'published Tool Profile releases cannot be deleted');
END;

CREATE TRIGGER tool_profile_acceptance_evidence_no_delete
BEFORE DELETE ON tool_profile_acceptance_evidence
BEGIN
  SELECT RAISE(ABORT, 'Tool Profile acceptance evidence cannot be deleted');
END;

CREATE TRIGGER tool_profile_local_qualification_no_delete
BEFORE DELETE ON tool_profile_local_qualification_evidence
BEGIN
  SELECT RAISE(ABORT, 'Tool Profile local qualification evidence cannot be deleted');
END;
