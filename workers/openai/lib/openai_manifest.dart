const openAiWorkerManifest = <String, Object?>{
  'workerId': 'conclave.openai',
  'version': '0.3.0',
  'displayName': 'OpenAI Worker',
  'description': 'OpenAI API Worker for structured model execution',
  'publisher': 'conclave-official',
  'channel': 'stable',
  'protocolVersion': '4.0',
  'minimumHostVersion': '0.1.0',
  'supportedOS': ['macos', 'linux', 'windows'],
  'supportedArchitecture': ['arm64', 'x64'],
  'roles': ['architect', 'coder', 'reviewer', 'evaluator'],
  'capabilities': ['structured_output', 'model_api'],
  'permissions': ['network:openai'],
  'credentialRequirements': [
    {
      'name': 'openai_api_key',
      'authMode': 'api_key',
      'sharingPolicy': 'workspace_capable',
      'required': true,
      'envVar': 'OPENAI_API_KEY'
    }
  ],
  'credentialSharingPolicy': 'workspace_capable',
  'configurationSchema': {
    'type': 'object',
    'properties': {
      'model': {'type': 'string'}
    }
  },
  'sessionModes': ['stateless'],
  'concurrencyModel': {
    'maxConcurrentAssignments': 10,
    'persistentRuntime': false,
    'isolation': 'thread'
  },
  'billingModes': ['api_metered'],
  'entrypoint': 'bin/openai_worker.dart',
  'digest': 'sha256:development',
  'signature': 'development',
};
