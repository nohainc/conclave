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
    this.installationId,
  });

  final String hostId;
  final String workspaceId;
  final String cloudUrl;
  final String name;
  final String hostname;
  final String? installationId;

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
      installationId: json['installationId'] is String
          ? (json['installationId'] as String).trim()
          : null,
    );
  }

  Map<String, Object?> toJson() => {
        'hostId': hostId,
        'workspaceId': workspaceId,
        'cloudUrl': cloudUrl,
        'name': name,
        'hostname': hostname,
        if (installationId != null) 'installationId': installationId,
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

/// Persistent, stable installation identity for one desktop Workspace install.
/// It is independent of hostname/hardware fingerprint and survives application
/// restarts, application updates, computer renames, and workspace renames.
class InstallationIdentityStore {
  const InstallationIdentityStore(this.dataDirectory, {this.platform});

  final Directory dataDirectory;
  final PlatformRuntime? platform;

  File get file =>
      File('${dataDirectory.path}${Platform.pathSeparator}installation-id');

  String? readSync() {
    if (!file.existsSync()) return null;
    try {
      final value = file.readAsStringSync().trim();
      return value.isNotEmpty ? value : null;
    } on Object {
      return null;
    }
  }

  Future<String> getOrCreate({String? initialIdentity}) async {
    if (await file.exists()) {
      final existing = (await file.readAsString()).trim();
      if (existing.isNotEmpty) return existing;
    }
    final identity = initialIdentity?.trim().isNotEmpty == true
        ? initialIdentity!.trim()
        : generateInstallationId();
    await dataDirectory.create(recursive: true);
    await file.writeAsString(identity, flush: true);
    await (platform ?? currentPlatformRuntime)
        .restrictPermissions(file.path, directory: false);
    return identity;
  }

  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }

  static String generateInstallationId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // UUID v4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // Variant 10xxxxxx
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final uuid =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
    return 'install_$uuid';
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
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // UUID v4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // Variant 10xxxxxx
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }
}
