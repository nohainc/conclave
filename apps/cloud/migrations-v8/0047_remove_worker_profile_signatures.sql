-- V9 Profile publication no longer creates or verifies cryptographic
-- signatures. Keep the current/history snapshots, digest, revision, actor,
-- and atomic publication semantics; remove only Tool Profile signing data.
-- Workspace application-release signing remains separate.

ALTER TABLE worker_profiles DROP COLUMN signature;
ALTER TABLE worker_profiles DROP COLUMN signing_key_id;
ALTER TABLE worker_profile_history DROP COLUMN signature;
ALTER TABLE worker_profile_history DROP COLUMN signing_key_id;
