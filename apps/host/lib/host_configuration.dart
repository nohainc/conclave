import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}

/// Stable local identity for Worker ownership. It exists before Cloud pairing
/// and survives re-pairing this machine to another Cloud Workspace.
class LocalWorkspaceIdentityStore {
  const LocalWorkspaceIdentityStore(this.dataDirectory, {this.platform});

  final Directory dataDirectory;
  final PlatformRuntime? platform;

  File get file =>
      File('${dataDirectory.path}${Platform.pathSeparator}local-workspace-id');

  Future<String> getOrCreate({String? initialIdentity}) async {
    if (await file.exists()) {
      final existing = (await file.readAsString()).trim();
      if (existing.isNotEmpty) return existing;
    }
    final identity = initialIdentity?.trim().isNotEmpty == true
        ? initialIdentity!.trim()
        : 'local-${_randomToken()}';
    await dataDirectory.create(recursive: true);
    await file.writeAsString(identity, flush: true);
    await (platform ?? currentPlatformRuntime)
        .restrictPermissions(file.path, directory: false);
    return identity;
  }

  static String _randomToken() {
    final random = Random.secure();
    return List<int>.generate(24, (_) => random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
