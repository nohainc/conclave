import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'secure_credentials.dart';
import 'workspace_configuration.dart';
import 'workspace_registration_models.dart';

export 'workspace_registration_models.dart';

class WorkspaceRegistrationClient {
  WorkspaceRegistrationClient({
    required this.cloudUrl,
    HttpClient? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? HttpClient();

  final String cloudUrl;
  final Duration timeout;
  final HttpClient _client;

  Future<WorkspaceRegistrationResult> register({
    required String credential,
    required SafeMachineFacts facts,
  }) async {
    final uri = workspaceCloudApiUri(
      cloudUrl,
      '/api/workspace-runtime/register',
    );
    final request = await _client.postUrl(uri).timeout(timeout);
    request.headers.contentType = ContentType.json;
    request.headers
        .set(HttpHeaders.authorizationHeader, 'Bearer ${credential.trim()}');
    final payload = facts.toRegistrationJson();
    payload['contractVersion'] = '1.0';
    payload['proposedWorkspaceName'] = payload.remove('name');
    request.write(jsonEncode(payload));
    final response = await request.close().timeout(timeout);
    final body = await utf8.decoder.bind(response).join().timeout(timeout);
    if (response.statusCode != HttpStatus.created) {
      String? detail;
      String? code;
      try {
        final parsed = jsonDecode(body);
        if (parsed is Map) {
          detail = parsed['error'] as String?;
          code = parsed['code'] as String?;
        }
      } on Object {
        detail = body;
      }
      throw WorkspaceRegistrationException.fromError(
        statusCode: response.statusCode,
        serverError: detail,
        serverCode: code,
      );
    }
    final parsed = jsonDecode(body);
    if (parsed is! Map) {
      throw const FormatException(
        'Workspace registration response is invalid.',
      );
    }
    return WorkspaceRegistrationResult.fromJson(
      Map<String, Object?>.from(parsed),
    );
  }

  void close() => _client.close(force: true);
}

class WorkspaceRegistrationService {
  WorkspaceRegistrationService({
    required this.dataDirectory,
    SecureCredentialStore credentialStore =
        const PlatformSecureCredentialStore(),
  }) : _credentialStore = credentialStore;

  final Directory dataDirectory;
  final SecureCredentialStore _credentialStore;

  Future<WorkspaceRegistration> registerWithDesktopSession({
    required String cloudUrl,
    required String desktopCredential,
    required SafeMachineFacts facts,
    required String expectedOwnerUserId,
  }) async {
    final client = WorkspaceRegistrationClient(cloudUrl: cloudUrl);
    try {
      final result = await client.register(
        credential: desktopCredential,
        facts: facts,
      );
      if (result.ownerUserId == null ||
          result.ownerUserId != expectedOwnerUserId) {
        throw StateError(
          'Cloud returned a Workspace owned by a different Conclave account.',
        );
      }
      await _credentialStore.write(
        result.workspaceRuntimeId,
        result.runtimeCredential,
      );
      final registration = WorkspaceRegistration(
        workspaceRuntimeId: result.workspaceRuntimeId,
        workspaceId: result.workspaceId,
        cloudUrl: normalizeWorkspaceCloudOrigin(cloudUrl),
        name: result.workspaceName,
        hostname: facts.hostname,
        ownerUserId: result.ownerUserId,
        installationId: facts.installationId,
      );
      try {
        await WorkspaceRegistrationStore(dataDirectory).write(registration);
      } on Object {
        await _credentialStore.delete(result.workspaceRuntimeId);
        rethrow;
      }
      return registration;
    } finally {
      client.close();
    }
  }
}
