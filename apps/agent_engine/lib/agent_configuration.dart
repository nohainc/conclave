import 'dart:convert';
import 'dart:io';

class AgentRegistration {
  const AgentRegistration({
    required this.agentId,
    required this.workspaceId,
    required this.cloudUrl,
    required this.name,
    required this.hostname,
  });

  final String agentId;
  final String workspaceId;
  final String cloudUrl;
  final String name;
  final String hostname;

  factory AgentRegistration.fromJson(Map<String, dynamic> json) {
    String required(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Agent registration field $key is required');
      }
      return value;
    }

    return AgentRegistration(
      agentId: required('agentId'),
      workspaceId: required('workspaceId'),
      cloudUrl: required('cloudUrl'),
      name: required('name'),
      hostname: required('hostname'),
    );
  }

  Map<String, Object?> toJson() => {
        'agentId': agentId,
        'workspaceId': workspaceId,
        'cloudUrl': cloudUrl,
        'name': name,
        'hostname': hostname,
      };
}

class AgentRegistrationStore {
  const AgentRegistrationStore(this.dataDirectory);

  final Directory dataDirectory;

  File get file => File('${dataDirectory.path}/agent-config.json');

  AgentRegistration? readSync() {
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map
          ? AgentRegistration.fromJson(Map<String, dynamic>.from(decoded))
          : null;
    } on Object {
      return null;
    }
  }

  Future<void> write(AgentRegistration registration) async {
    await dataDirectory.create(recursive: true);
    await file.writeAsString(jsonEncode(registration.toJson()), flush: true);
    await Process.run('chmod', ['600', file.path]);
  }
}
