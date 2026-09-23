const forgeWorkerManifest = <String, Object?>{
  'workerId': 'conclave.forge',
  'version': '0.2.0',
  'displayName': 'Forge Worker',
  'description': 'Repository verification and completion Worker',
  'publisher': 'conclave-official',
  'channel': 'development',
  'protocolVersion': '4.0',
  'minimumHostVersion': '0.1.0',
  'supportedOS': ['macos', 'linux', 'windows'],
  'supportedArchitecture': ['arm64', 'x64'],
  'roles': ['verifier', 'implementer'],
  'capabilities': ['repository_access', 'code_execution', 'verification'],
  'permissions': ['workspace:read', 'workspace:write', 'process:spawn'],
  'credentialRequirements': [
    {'authMode': 'none', 'required': false}
  ],
  'credentialSharingPolicy': 'workspace_capable',
  'configurationSchema': {'type': 'object'},
  'sessionModes': ['isolated_workspace'],
  'concurrencyModel': {
    'maxConcurrentAssignments': 1,
    'persistentRuntime': false,
    'isolation': 'process'
  },
  'entrypoint': 'bin/forge_worker.dart',
  'billingModes': ['local_compute'],
  'digest': 'sha256:development',
  'signature': 'development',
};
