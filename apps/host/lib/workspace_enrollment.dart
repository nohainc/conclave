import 'dart:convert';
import 'dart:io';

import 'host_configuration.dart';
import 'secure_credentials.dart';

const conclaveProductionCloudUrl = 'https://app.conclaveax.com';
const conclaveWorkspaceAppVersion =
    String.fromEnvironment('CONCLAVE_WORKSPACE_VERSION', defaultValue: '1.0.3');

class WorkspaceEnrollmentResult {
  const WorkspaceEnrollmentResult({
    required this.workspaceRuntimeId,
    required this.workspaceId,
    required this.workspaceName,
    required this.authToken,
  });

  final String workspaceRuntimeId;
  final String workspaceId;
  final String workspaceName;
  final String authToken;

  factory WorkspaceEnrollmentResult.fromJson(Map<String, Object?> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Workspace enrollment response is missing $key');
      }
      return value.trim();
    }

    return WorkspaceEnrollmentResult(
      workspaceRuntimeId: requiredString('workspaceRuntimeId'),
      workspaceId: requiredString('workspaceId'),
      workspaceName: requiredString('workspaceName'),
      authToken: requiredString('authToken'),
    );
  }
}

/// Safe machine facts submitted during Workspace claim/enrollment.
///
/// Under the Conclave safety contract, this payload contains only safe,
/// non-sensitive platform metadata and runtime capabilities. It MUST NEVER
/// contain API keys, credentials, cookies, private paths, or filesystem contents.
class SafeMachineFacts {
  const SafeMachineFacts({
    required this.installationId,
    required this.name,
    required this.hostname,
    required this.platform,
    required this.architecture,
    required this.appVersion,
    required this.runtimeCapabilities,
  });

  final String installationId;
  final String name;
  final String hostname;
  final String platform;
  final String architecture;
  final String appVersion;
  final Map<String, Object?> runtimeCapabilities;

  Map<String, Object?> toJson({required String token}) {
    final payload = <String, Object?>{
      'token': token.trim(),
      'hostname': hostname.trim(),
      if (name.trim().isNotEmpty) 'name': name.trim(),
      if (installationId.trim().isNotEmpty)
        'installationId': installationId.trim(),
      'platform': platform.trim(),
      'architecture': architecture.trim(),
      'appVersion': appVersion.trim(),
      'runtimeCapabilities': runtimeCapabilities,
    };
    validateSafePayload(payload);
    return payload;
  }

  static SafeMachineFacts collect({
    required String installationId,
    required String name,
    String? hostname,
    String? platform,
    String? architecture,
    String? appVersion,
    Map<String, Object?>? capabilities,
  }) {
    final os = platform ?? Platform.operatingSystem;
    final arch = architecture ?? detectArchitecture();
    final ver = appVersion ?? conclaveWorkspaceAppVersion;
    final host = hostname ?? Platform.localHostname;
    final caps = capabilities ??
        defaultRuntimeCapabilities(os: os, arch: arch, appVersion: ver);

    return SafeMachineFacts(
      installationId: installationId,
      name: name,
      hostname: host,
      platform: os,
      architecture: arch,
      appVersion: ver,
      runtimeCapabilities: caps,
    );
  }

  static Map<String, Object?> defaultRuntimeCapabilities({
    required String os,
    required String arch,
    required String appVersion,
  }) {
    return {
      'os': os,
      'arch': arch,
      'appVersion': appVersion,
      'supportedRuntimes': const <String>['dart'],
      'maxConcurrentWorkers': 1,
    };
  }

  static String detectArchitecture() {
    final version = Platform.version.toLowerCase();
    final envHint =
        '${Platform.environment['PROCESSOR_ARCHITECTURE'] ?? ''} ${Platform.environment['HOSTTYPE'] ?? ''}'
            .toLowerCase();
    if (version.contains('arm64') ||
        version.contains('aarch64') ||
        envHint.contains('arm64') ||
        envHint.contains('aarch64')) {
      return 'arm64';
    }
    return 'x64';
  }

  /// Verifies that no sensitive keys or paths are present in machine facts.
  static void validateSafePayload(Map<String, Object?> payload) {
    const forbidden = {
      'apikey',
      'api_key',
      'secret',
      'secrets',
      'password',
      'cookie',
      'cookies',
      'credential',
      'credentials',
      'authtoken',
      'auth_token',
      'homedirectory',
      'home_directory',
      'workroot',
      'work_root',
      'filesystem',
      'inventory',
    };

    void scan(Object? value, [String path = '']) {
      if (value is Map) {
        for (final entry in value.entries) {
          final key = entry.key.toString().toLowerCase().replaceAll('_', '');
          if (forbidden.contains(key) && entry.key != 'token') {
            throw ArgumentError(
                'Prohibited secret or sensitive metadata in machine facts: ${entry.key}');
          }
          scan(entry.value, '$path.${entry.key}');
        }
      } else if (value is List) {
        for (final item in value) {
          scan(item, path);
        }
      }
    }

    scan(payload);
  }
}

class WorkspaceEnrollmentClient {
  WorkspaceEnrollmentClient({
    required this.cloudUrl,
    HttpClient? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? HttpClient();

  final String cloudUrl;
  final Duration timeout;
  final HttpClient _client;

  Future<WorkspaceEnrollmentResult> redeem({
    required String token,
    required String hostname,
    String? proposedWorkspaceName,
    String? installationId,
    Map<String, Object?>? runtimeCapabilities,
  }) async {
    final base = Uri.tryParse(cloudUrl.trim());
    if (base == null ||
        !const {'https', 'http'}.contains(base.scheme) ||
        base.host.isEmpty) {
      throw ArgumentError('Cloud URL must be an HTTP(S) origin.');
    }
    if (token.trim().isEmpty) {
      throw ArgumentError('Pairing code is required.');
    }

    final safeFacts = SafeMachineFacts.collect(
      installationId: installationId ?? '',
      name: proposedWorkspaceName ?? hostname,
      hostname: hostname,
      capabilities: runtimeCapabilities,
    );

    final uri = base.replace(
      path:
          '${base.path.replaceFirst(RegExp(r'/$'), '')}/api/workspace-runtime/enroll',
      query: null,
      fragment: null,
    );
    final request = await _client.postUrl(uri).timeout(timeout);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(safeFacts.toJson(token: token)));
    final response = await request.close().timeout(timeout);
    final body = await utf8.decoder.bind(response).join().timeout(timeout);
    if (response.statusCode != HttpStatus.created) {
      var detail = body.trim();
      try {
        final parsed = jsonDecode(body);
        if (parsed is Map && parsed['error'] is String) {
          detail = parsed['error'] as String;
        }
      } on Object {
        // Preserve the text response when Cloud did not return JSON.
      }
      throw StateError(
        'Pairing failed (HTTP ${response.statusCode})'
        '${detail.isEmpty ? '' : ': $detail'}',
      );
    }
    final parsed = jsonDecode(body);
    if (parsed is! Map) {
      throw const FormatException('Workspace enrollment response is invalid.');
    }
    return WorkspaceEnrollmentResult.fromJson(
      Map<String, Object?>.from(parsed),
    );
  }

  void close() => _client.close(force: true);
}

class WorkspacePairingService {
  WorkspacePairingService({
    required this.dataDirectory,
    SecureCredentialStore credentialStore =
        const PlatformSecureCredentialStore(),
  }) : _credentialStore = credentialStore;

  final Directory dataDirectory;
  final SecureCredentialStore _credentialStore;

  static Future<void> unpair({
    required String cloudUrl,
    required String token,
  }) async {
    final base = Uri.tryParse(cloudUrl.trim());
    if (base == null ||
        !const {'https', 'http'}.contains(base.scheme) ||
        base.host.isEmpty) {
      throw ArgumentError('Cloud URL must be an HTTP(S) origin.');
    }
    if (token.trim().isEmpty) {
      throw ArgumentError('Workspace runtime credential is required.');
    }
    final uri = base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/$'), '')}'
          '/api/workspace-runtime/unpair',
      query: null,
      fragment: null,
    );
    final client = HttpClient();
    try {
      final request = await client.postUrl(uri).timeout(
            const Duration(seconds: 20),
          );
      request.headers
          .set(HttpHeaders.authorizationHeader, 'Bearer ${token.trim()}');
      final response = await request.close().timeout(
            const Duration(seconds: 20),
          );
      final body = await utf8.decoder.bind(response).join().timeout(
            const Duration(seconds: 20),
          );
      if (response.statusCode != HttpStatus.ok) {
        var detail = body.trim();
        try {
          final parsed = jsonDecode(body);
          if (parsed is Map && parsed['error'] is String) {
            detail = parsed['error'] as String;
          }
        } on Object {
          // Use the response text when Cloud returns a non-JSON error.
        }
        throw StateError(
          'Unpair failed (HTTP ${response.statusCode})'
          '${detail.isEmpty ? '' : ': $detail'}',
        );
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<HostRegistration> pair({
    required String cloudUrl,
    required String token,
    required String hostname,
    String? proposedWorkspaceName,
    String? installationId,
    bool force = false,
  }) async {
    final existing = HostRegistrationStore(dataDirectory).readSync();
    if (existing != null && !force) {
      throw StateError(
        'This installation is already connected to a Workspace. '
        'Disconnect the current Workspace before connecting to another account.',
      );
    }

    final client = WorkspaceEnrollmentClient(cloudUrl: cloudUrl);
    try {
      final result = await client.redeem(
        token: token,
        hostname: hostname,
        proposedWorkspaceName: proposedWorkspaceName,
        installationId: installationId,
      );
      final previous = HostRegistrationStore(dataDirectory).readSync();
      await _credentialStore.write(
        result.workspaceRuntimeId,
        result.authToken,
      );
      final registration = HostRegistration(
        hostId: result.workspaceRuntimeId,
        workspaceId: result.workspaceId,
        cloudUrl: cloudUrl.trim().replaceFirst(RegExp(r'/$'), ''),
        name: proposedWorkspaceName?.trim().isNotEmpty == true
            ? proposedWorkspaceName!.trim()
            : result.workspaceName,
        hostname: hostname,
        installationId: installationId,
      );
      try {
        await HostRegistrationStore(dataDirectory).write(registration);
      } on Object {
        await _credentialStore.delete(result.workspaceRuntimeId);
        rethrow;
      }
      if (previous != null && previous.hostId != result.workspaceRuntimeId) {
        await _credentialStore.delete(previous.hostId);
      }
      return registration;
    } finally {
      client.close();
    }
  }
}
