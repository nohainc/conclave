-- Global execution configuration belongs to users. Thread configuration retains
-- authored context only. Do not copy ambiguous Space/Thread choices to a user.
-- Immutable accepted Work Request snapshots and historical runs are untouched.
UPDATE thread_work_configs
SET config_json = json_set(config_json, '$.bindings', json(COALESCE((
  SELECT json_group_object(binding.key, json_object('additionalInstructions',
    trim(json_extract(binding.value, '$.additionalInstructions'))))
  FROM json_each(thread_work_configs.config_json, '$.bindings') AS binding
  WHERE binding.key IN ('direct','chat','research','plan','implement','test','verify')
    AND json_type(binding.value, '$.additionalInstructions') = 'text'
    AND length(trim(json_extract(binding.value, '$.additionalInstructions'))) > 0
), '{}')));
