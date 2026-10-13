-- Revert only the Gemini mappings introduced by 0050 and 0051.
-- Restore the exact original payload from immutable history as a new revision.
-- Customized/newer payloads are untouched; absent history fails closed.

INSERT INTO worker_profile_history (worker_type_id, revision, schema_version, profile_json, digest, actor_user_id, published_at, restoration_reason)
SELECT worker_type_id, revision, schema_version, profile_json, digest, updated_by_user_id, updated_at, 'User-requested reversal of Gemini model mappings'
FROM worker_profiles
WHERE worker_type_id = 'gemini' AND digest = '24d50d6389a6179d17ebe6fb1e1f81e304f5d9887839731735f81cc151ebce40'
AND EXISTS (SELECT 1 FROM worker_profile_history WHERE worker_type_id = 'gemini' AND digest = 'ac71f61cd7760f54a632d5024e428bd4fdad1fd90fd59f0c600d26fef0985a34');

UPDATE worker_profiles
SET profile_json = (SELECT profile_json FROM worker_profile_history WHERE worker_type_id = 'gemini' AND digest = 'ac71f61cd7760f54a632d5024e428bd4fdad1fd90fd59f0c600d26fef0985a34' ORDER BY revision DESC LIMIT 1),
    digest = 'ac71f61cd7760f54a632d5024e428bd4fdad1fd90fd59f0c600d26fef0985a34', revision = revision + 1,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE worker_type_id = 'gemini' AND digest = '24d50d6389a6179d17ebe6fb1e1f81e304f5d9887839731735f81cc151ebce40'
AND EXISTS (SELECT 1 FROM worker_profile_history WHERE worker_type_id = 'gemini' AND digest = 'ac71f61cd7760f54a632d5024e428bd4fdad1fd90fd59f0c600d26fef0985a34');

INSERT INTO worker_profile_history (worker_type_id, revision, schema_version, profile_json, digest, actor_user_id, published_at, restoration_reason)
SELECT worker_type_id, revision, schema_version, profile_json, digest, updated_by_user_id, updated_at, 'User-requested reversal of Gemini model mappings'
FROM worker_profiles
WHERE worker_type_id = 'gemini' AND digest = '23dd2cef514bac63dad017836ab883b44a3a522f9a54319d9d9af04a3a044892'
AND EXISTS (SELECT 1 FROM worker_profile_history WHERE worker_type_id = 'gemini' AND digest = 'f6200b09939980130cd5b963fbf4954ee988804bfc5e77938a9e9a75001dfa29');

UPDATE worker_profiles
SET profile_json = (SELECT profile_json FROM worker_profile_history WHERE worker_type_id = 'gemini' AND digest = 'f6200b09939980130cd5b963fbf4954ee988804bfc5e77938a9e9a75001dfa29' ORDER BY revision DESC LIMIT 1),
    digest = 'f6200b09939980130cd5b963fbf4954ee988804bfc5e77938a9e9a75001dfa29', revision = revision + 1,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE worker_type_id = 'gemini' AND digest = '23dd2cef514bac63dad017836ab883b44a3a522f9a54319d9d9af04a3a044892'
AND EXISTS (SELECT 1 FROM worker_profile_history WHERE worker_type_id = 'gemini' AND digest = 'f6200b09939980130cd5b963fbf4954ee988804bfc5e77938a9e9a75001dfa29');
