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

    final uri = base.replace(
      path:
          '${base.path.replaceFirst(RegExp(r'/$'), '')}/api/workspace-runtime/enroll',
      query: null,
      fragment: null,
    );
    final request = await _client.postUrl(uri).timeout(timeout);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({
      'token': token.trim(),
      'hostname': hostname,
      'platform': Platform.operatingSystem,
      'architecture': _architecture(),
      'appVersion': conclaveWorkspaceAppVersion,
    }));
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

  static String _architecture() {
    final version = Platform.version.toLowerCase();
    if (version.contains('arm64') || version.contains('aarch64')) return 'arm64';
    return 'x64';
  }
}

class WorkspacePairingService {
  WorkspacePairingService({
    required this.dataDirectory,
    SecureCredentialStore credentialStore = const PlatformSecureCredentialStore(),
  }) : _credentialStore = credentialStore;

  final Directory dataDirectory;
  final SecureCredentialStore _credentialStore;

  Future<HostRegistration> pair({
    required String cloudUrl,
    required String token,
    required String hostname,
  }) async {
    final client = WorkspaceEnrollmentClient(cloudUrl: cloudUrl);
    try {
      final result = await client.redeem(token: token, hostname: hostname);
      final previous = HostRegistrationStore(dataDirectory).readSync();
      await _credentialStore.write(
        result.workspaceRuntimeId,
        result.authToken,
      );
      final registration = HostRegistration(
        hostId: result.workspaceRuntimeId,
        workspaceId: result.workspaceId,
        cloudUrl: cloudUrl.trim().replaceFirst(RegExp(r'/$'), ''),
        name: result.workspaceName,
        hostname: hostname,
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
