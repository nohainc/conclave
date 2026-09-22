const openAiPluginManifest = <String, Object?>{
  'pluginId': 'conclave.openai',
  'version': '0.2.0',
  'protocolVersion': '2.0',
  'minimumAgentVersion': '0.1.0',
  'roles': ['architect', 'coder', 'reviewer', 'evaluator'],
  'capabilities': ['structured_output', 'model_api'],
  'permissions': ['network:openai'],
  'billingModes': ['api_metered'],
  'entrypoint': 'bin/openai_worker.dart',
};
