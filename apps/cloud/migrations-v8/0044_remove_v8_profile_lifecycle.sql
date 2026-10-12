-- V9 cleanup: remove the V8 release/channel persistence only after all
-- production readers and writers use worker_profiles/current history.
-- Applied migration files are never rewritten or renumbered.

DROP TABLE IF EXISTS tool_profile_local_qualification_evidence;
DROP TABLE IF EXISTS tool_profile_acceptance_evidence;
DROP TABLE IF EXISTS tool_profile_release_audit;
DROP TABLE IF EXISTS tool_profile_channel_pointers;
DROP TABLE IF EXISTS workspace_tool_profile_channels;
DROP TABLE IF EXISTS tool_profile_releases;
DROP TABLE IF EXISTS tool_profile_starter_templates;
DROP TABLE IF EXISTS tool_profile_definitions;
