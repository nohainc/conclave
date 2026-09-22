const anthropicPluginManifest = <String, Object?>{
  'pluginId': 'conclave.anthropic',
  'version': '0.2.0',
  'protocolVersion': '2.0',
  'minimumAgentVersion': '0.1.0',
  'roles': ['architect', 'coder', 'reviewer', 'evaluator'],
  'capabilities': ['structured_output', 'model_api'],
  'permissions': ['network:anthropic'],
  'billingModes': ['api_metered'],
  'entrypoint': 'bin/anthropic_worker.dart',
};
