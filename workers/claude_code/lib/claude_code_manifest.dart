const claudeCodeWorkerManifest = <String, Object?>{
  'workerId': 'conclave.claude-code',
  'version': '0.3.0',
  'displayName': 'Claude Code Worker',
  'description':
      'Claude Code CLI Worker for repository implementation and review',
  'publisher': 'conclave-official',
  'channel': 'stable',
  'protocolVersion': '4.0',
  'minimumHostVersion': '0.1.0',
  'supportedOS': ['macos', 'linux', 'windows'],
  'supportedArchitecture': ['arm64', 'x64'],
  'roles': ['architect', 'coder', 'implementer', 'reviewer'],
  'capabilities': ['code_execution', 'file_system', 'structured_output'],
  'permissions': ['workspace:read', 'workspace:write'],
  'credentialRequirements': [
    {'name': 'claude_auth', 'authMode': 'local_cli_session', 'required': true}
  ],
  'credentialSharingPolicy': 'private_only',
  'configurationSchema': {
    'type': 'object',
    'properties': {
      'model': {'type': 'string'}
    }
  },
  'sessionModes': ['isolated_workspace', 'reuse_session'],
  'concurrencyModel': {
    'maxConcurrentAssignments': 1,
    'persistentRuntime': false,
    'isolation': 'process'
  },
  'billingModes': ['subscription'],
  'entrypoint': 'bin/claude_code_worker.dart',
  'digest': 'sha256:development',
  'signature': 'development',
};
