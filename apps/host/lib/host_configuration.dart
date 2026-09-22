import 'dart:convert';
import 'dart:io';

import 'platform_runtime.dart';

class HostRegistration {
  const HostRegistration({
    required this.hostId,
    required this.workspaceId,
    required this.cloudUrl,
    required this.name,
    required this.hostname,
  });

  final String hostId;
  final String workspaceId;
  final String cloudUrl;
  final String name;
  final String hostname;

  factory HostRegistration.fromJson(Map<String, dynamic> json) {
    String required(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Host registration field $key is required');
      }
      return value;
    }

    return HostRegistration(
      hostId: required('hostId'),
      workspaceId: required('workspaceId'),
      cloudUrl: required('cloudUrl'),
      name: required('name'),
      hostname: required('hostname'),
    );
  }

  Map<String, Object?> toJson() => {
        'hostId': hostId,
        'workspaceId': workspaceId,
        'cloudUrl': cloudUrl,
        'name': name,
        'hostname': hostname,
      };
}

class HostRegistrationStore {
  const HostRegistrationStore(this.dataDirectory, {this.platform});

  final Directory dataDirectory;
  final PlatformRuntime? platform;

  File get file =>
      File('${dataDirectory.path}${Platform.pathSeparator}host-config.json');

  HostRegistration? readSync() {
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map
          ? HostRegistration.fromJson(Map<String, dynamic>.from(decoded))
          : null;
    } on Object {
      return null;
    }
  }

  Future<void> write(HostRegistration registration) async {
    await dataDirectory.create(recursive: true);
    await file.writeAsString(jsonEncode(registration.toJson()), flush: true);
    await (platform ?? currentPlatformRuntime)
        .restrictPermissions(file.path, directory: false);
  }
}
