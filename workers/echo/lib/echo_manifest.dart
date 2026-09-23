const echoWorkerManifest = <String, Object?>{
  'workerId': 'conclave.echo',
  'version': '1.1.0',
  'displayName': 'Echo Worker',
  'description': 'Deterministic Worker used for Host protocol acceptance tests',
  'publisher': 'conclave-official',
  'channel': 'development',
  'protocolVersion': '4.0',
  'minimumHostVersion': '0.1.0',
  'supportedOS': ['macos', 'linux', 'windows'],
  'supportedArchitecture': ['arm64', 'x64'],
  'roles': ['verifier', 'tester'],
  'capabilities': ['deterministic_echo', 'structured_output'],
  'permissions': [],
  'credentialRequirements': [
    {'authMode': 'none', 'required': false}
  ],
  'credentialSharingPolicy': 'workspace_capable',
  'configurationSchema': {
    'type': 'object',
    'properties': {
      'delayMs': {'type': 'integer'}
    }
  },
  'sessionModes': ['stateless', 'isolated_workspace'],
  'concurrencyModel': {
    'maxConcurrentAssignments': 4,
    'persistentRuntime': false,
    'isolation': 'process'
  },
  'entrypoint': 'bin/echo_worker.dart',
  'billingModes': ['free'],
  'digest': 'sha256:development',
  'signature': 'development',
};
