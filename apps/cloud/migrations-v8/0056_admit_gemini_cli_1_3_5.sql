-- Admit the Antigravity CLI 1.3.5 release in the single published Gemini Profile.
-- Keep the update idempotent and preserve the previous published payload in history.

INSERT INTO worker_profile_history (
  worker_type_id, revision, schema_version, profile_json, digest,
  actor_user_id, published_at, restoration_reason
)
SELECT worker_type_id, revision, schema_version, profile_json, digest,
       updated_by_user_id, updated_at, 'Admit Antigravity CLI 1.3.5'
  FROM worker_profiles
 WHERE worker_type_id = 'gemini'
   AND digest = '23dd2cef514bac63dad017836ab883b44a3a522f9a54319d9d9af04a3a044892';

UPDATE worker_profiles
   SET profile_json = json_set(
         profile_json,
         '$.providerTool.supportedVersions[2].maxExclusive',
         '1.3.6'
       ),
       digest = 'a978c7a9ba029a4ee2d72a587a0acf63c8ad3a322bcf78b244cd89b9d7c102d1',
       revision = revision + 1,
       updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
 WHERE worker_type_id = 'gemini'
   AND digest = '23dd2cef514bac63dad017836ab883b44a3a522f9a54319d9d9af04a3a044892'
   AND json_extract(profile_json, '$.providerTool.supportedVersions[2].min') = '1.3.4'
   AND json_extract(profile_json, '$.providerTool.supportedVersions[2].maxExclusive') = '1.3.5';
