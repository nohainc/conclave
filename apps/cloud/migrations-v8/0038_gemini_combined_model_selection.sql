-- Publish the combined Gemini model/effort contract to the authoring starter.
-- Existing signed releases remain immutable; the next qualified release must
-- be produced from this starter and promoted before Workspace clients use it.
UPDATE tool_profile_starter_templates
SET profile_json = json_remove(json_set(
  json_remove(
    json_set(profile_json, '$.model.executionOptions', NULL),
    '$.model.executionOptions',
    '$.execution.arguments[5]'
  ),
  '$.engineCompatibility.min', '1.2.0',
  '$.model.selectionMode', 'combined',
  '$.model.selectionMapping', json('{"schemaVersion":1,"models":[{"id":"gemini-3.8-flash","name":"Gemini 3.8 Flash","variants":[{"nativeId":"gemini-3.8-flash-low","effort":"low","providerVersion":{"min":"1.3.3","maxExclusive":"1.3.4"}},{"nativeId":"gemini-3.8-flash-medium","effort":"medium","providerVersion":{"min":"1.3.3","maxExclusive":"1.3.4"}},{"nativeId":"gemini-3.8-flash-high","effort":"high","providerVersion":{"min":"1.3.3","maxExclusive":"1.3.4"}}]},{"id":"gemini-3.7-flash","name":"Gemini 3.7 Flash","variants":[{"nativeId":"gemini-3.7-flash-low","effort":"low","providerVersion":{"min":"1.3.3","maxExclusive":"1.3.4"}},{"nativeId":"gemini-3.7-flash-medium","effort":"medium","providerVersion":{"min":"1.3.3","maxExclusive":"1.3.4"}},{"nativeId":"gemini-3.7-flash-high","effort":"high","providerVersion":{"min":"1.3.3","maxExclusive":"1.3.4"}}]},{"id":"gemini-3.6-flash","name":"Gemini 3.6 Flash","variants":[{"nativeId":"gemini-3.6-flash-low","effort":"low","providerVersion":{"min":"1.3.3","maxExclusive":"1.3.4"}},{"nativeId":"gemini-3.6-flash-medium","effort":"medium","providerVersion":{"min":"1.3.3","maxExclusive":"1.3.4"}},{"nativeId":"gemini-3.6-flash-high","effort":"high","providerVersion":{"min":"1.3.3","maxExclusive":"1.3.4"}}]},{"id":"gemini-3.1-pro","name":"Gemini 3.1 Pro","variants":[{"nativeId":"gemini-3.1-pro-low","effort":"low","providerVersion":{"min":"1.3.3","maxExclusive":"1.3.4"}},{"nativeId":"gemini-3.1-pro-high","effort":"high","providerVersion":{"min":"1.3.3","maxExclusive":"1.3.4"}}]}]}')
),
  '$.model.selectionMapping.models[0].variants[0].providerVersion',
  '$.model.selectionMapping.models[0].variants[1].providerVersion',
  '$.model.selectionMapping.models[0].variants[2].providerVersion',
  '$.model.selectionMapping.models[1].variants[0].providerVersion',
  '$.model.selectionMapping.models[1].variants[1].providerVersion',
  '$.model.selectionMapping.models[1].variants[2].providerVersion',
  '$.model.selectionMapping.models[2].variants[0].providerVersion',
  '$.model.selectionMapping.models[2].variants[1].providerVersion',
  '$.model.selectionMapping.models[2].variants[2].providerVersion',
  '$.model.selectionMapping.models[3].variants[0].providerVersion',
  '$.model.selectionMapping.models[3].variants[1].providerVersion'
)
WHERE profile_definition_id = 'gemini-antigravity'
  AND json_valid(profile_json) = 1;
