const claudeCodePluginManifest = <String, Object?>{
  'pluginId': 'conclave.claude-code',
  'version': '0.2.0',
  'protocolVersion': '2.0',
  'minimumAgentVersion': '0.1.0',
  'roles': ['architect', 'coder', 'implementer', 'reviewer'],
  'capabilities': ['code_execution', 'file_system', 'structured_output'],
  'permissions': ['workspace:read', 'workspace:write'],
  'billingModes': ['subscription'],
  'entrypoint': 'bin/claude_code_plugin.dart',
};
