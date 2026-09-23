const anthropicWorkerManifest = <String, Object?>{
  'workerId': 'conclave.anthropic',
  'version': '0.3.0',
  'displayName': 'Anthropic Worker',
  'description': 'Anthropic API Worker for structured model execution',
  'publisher': 'conclave-official',
  'channel': 'stable',
  'protocolVersion': '4.0',
  'minimumHostVersion': '0.1.0',
  'supportedOS': ['macos', 'linux', 'windows'],
  'supportedArchitecture': ['arm64', 'x64'],
  'roles': ['architect', 'coder', 'reviewer', 'evaluator'],
  'capabilities': ['structured_output', 'model_api'],
  'permissions': ['network:anthropic'],
  'credentialRequirements': [
    {
      'name': 'anthropic_api_key',
      'authMode': 'api_key',
      'sharingPolicy': 'workspace_capable',
      'required': true,
      'envVar': 'ANTHROPIC_API_KEY'
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
    'maxConcurrentAssignments': 8,
    'persistentRuntime': false,
    'isolation': 'process'
  },
  'billingModes': ['api_metered'],
  'entrypoint': 'bin/anthropic_worker.dart',
  'digest': 'sha256:development',
  'signature': 'development',
};
