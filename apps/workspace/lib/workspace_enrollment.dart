import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'workspace_configuration.dart';
import 'secure_credentials.dart';
import 'workspace_enrollment_models.dart';

export 'workspace_enrollment_models.dart';

class WorkspaceEnrollmentClient {
  WorkspaceEnrollmentClient({
    required this.cloudUrl,
    HttpClient? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? HttpClient();

  final String cloudUrl;
  final Duration timeout;
  final HttpClient _client;

  Future<WorkspaceEnrollmentResult> register({
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
    final payload = facts.toJson(token: 'desktop-registration');
    payload.remove('token');
    payload['contractVersion'] = '1.0';
    payload['proposedWorkspaceName'] = payload.remove('name');
    request.write(jsonEncode(payload));
    final response = await request.close().timeout(timeout);
    final body = await utf8.decoder.bind(response).join().timeout(timeout);
    if (response.statusCode != HttpStatus.created) {
      String? detail, code;
      try {
        final parsed = jsonDecode(body);
        if (parsed is Map) {
          detail = parsed['error'] as String?;
          code = parsed['code'] as String?;
        }
      } on Object {
        detail = body;
      }
      throw WorkspacePairingException.fromError(
          statusCode: response.statusCode,
          serverError: detail,
          serverCode: code);
    }
    final parsed = jsonDecode(body);
    if (parsed is! Map) {
      throw const FormatException(
          'Workspace registration response is invalid.');
    }
    return WorkspaceEnrollmentResult.fromJson(
        Map<String, Object?>.from(parsed));
  }

  Future<WorkspaceEnrollmentResult> redeem({
    required String token,
    required String hostname,
    String? proposedWorkspaceName,
    required String installationId,
    Map<String, Object?>? runtimeCapabilities,
    bool allowRecovery = false,
  }) async {
    Uri uri;
    try {
      uri = workspaceCloudApiUri(cloudUrl, '/api/workspace-runtime/enroll');
    } on ArgumentError {
      throw const WorkspacePairingException(
        kind: WorkspacePairingErrorKind.cloudUnavailable,
        message: 'Invalid Conclave Cloud URL.',
        action: 'Enter a valid HTTP(S) URL in advanced options.',
      );
    }
    if (token.trim().isEmpty) {
      throw const WorkspacePairingException(
        kind: WorkspacePairingErrorKind.invalidCode,
        message: 'Pairing code is required.',
        action: 'Paste the pairing code from Conclave AX.',
      );
    }

    final safeFacts = SafeMachineFacts.collect(
      installationId: installationId,
      name: proposedWorkspaceName ?? hostname,
      hostname: hostname,
      capabilities: runtimeCapabilities,
    );

    try {
      final request = await _client.postUrl(uri).timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(
            safeFacts.toJson(token: token, allowRecovery: allowRecovery)),
      );
      final response = await request.close().timeout(timeout);
      final body = await utf8.decoder.bind(response).join().timeout(timeout);
      if (response.statusCode != HttpStatus.created) {
        String? detail;
        String? code;
        try {
          final parsed = jsonDecode(body);
          if (parsed is Map) {
            if (parsed['error'] is String) detail = parsed['error'] as String;
            if (parsed['code'] is String) code = parsed['code'] as String;
          }
        } on Object {
          detail = body.trim();
        }
        throw WorkspacePairingException.fromError(
          statusCode: response.statusCode,
          serverError: detail,
          serverCode: code,
        );
      }
      final parsed = jsonDecode(body);
      if (parsed is! Map) {
        throw const WorkspacePairingException(
          kind: WorkspacePairingErrorKind.serverValidationFailure,
          message: 'Workspace enrollment response is invalid.',
          action: 'Contact support if this error persists.',
        );
      }
      return WorkspaceEnrollmentResult.fromJson(
        Map<String, Object?>.from(parsed),
      );
    } on WorkspacePairingException {
      rethrow;
    } on Object catch (e) {
      throw WorkspacePairingException.fromError(underlyingError: e);
    }
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

  Future<WorkspaceRegistration> registerWithDesktopSession({
    required String cloudUrl,
    required String desktopCredential,
    required SafeMachineFacts facts,
    required String expectedOwnerUserId,
  }) async {
    final client = WorkspaceEnrollmentClient(cloudUrl: cloudUrl);
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
      await _credentialStore.write(result.workspaceRuntimeId, result.authToken);
      final registration = WorkspaceRegistration(
        workspaceRuntimeId: result.workspaceRuntimeId,
        workspaceId: result.workspaceId,
        cloudUrl: normalizeWorkspaceCloudOrigin(cloudUrl),
        name: result.workspaceName,
        hostname: facts.hostname,
        ownerUserId: result.ownerUserId,
        installationId: facts.installationId,
        pairedAt: DateTime.now().toUtc().toIso8601String(),
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

  /// Clears only the stale Cloud registration after its Workspace has been
  /// revoked in AX. Stable installation identity and local Worker state stay
  /// in place so the desktop can claim a fresh pairing intent.
  Future<void> preparePairingRecovery() async {
    final registration = WorkspaceRegistrationStore(dataDirectory).readSync();
    await InstallationIdentityStore(dataDirectory).authorizeRecovery();
    if (registration != null) {
      await _credentialStore.delete(registration.workspaceRuntimeId);
    }
    await WorkspaceRegistrationStore(dataDirectory).clear();
  }

  static Future<void> unpair({
    required String cloudUrl,
    required String token,
  }) async {
    if (token.trim().isEmpty) {
      throw ArgumentError('Workspace runtime credential is required.');
    }
    final uri = workspaceCloudApiUri(
      cloudUrl,
      '/api/workspace-runtime/unpair',
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

  Future<WorkspaceRegistration> pair({
    required String cloudUrl,
    required String token,
    required String hostname,
    String? proposedWorkspaceName,
    required String installationId,
    bool allowRecovery = false,
  }) async {
    final existing = WorkspaceRegistrationStore(dataDirectory).readSync();
    if (existing != null) {
      throw const WorkspacePairingException(
        kind: WorkspacePairingErrorKind.installationAlreadyPaired,
        message: 'This installation is already connected to a Workspace.',
        action:
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
        allowRecovery: allowRecovery,
      );
      final previous = WorkspaceRegistrationStore(dataDirectory).readSync();
      await _credentialStore.write(
        result.workspaceRuntimeId,
        result.authToken,
      );
      final now = DateTime.now().toUtc().toIso8601String();
      final registration = WorkspaceRegistration(
        workspaceRuntimeId: result.workspaceRuntimeId,
        workspaceId: result.workspaceId,
        cloudUrl: normalizeWorkspaceCloudOrigin(cloudUrl),
        name: result.workspaceName.trim().isNotEmpty
            ? result.workspaceName.trim()
            : (proposedWorkspaceName?.trim().isNotEmpty == true
                ? proposedWorkspaceName!.trim()
                : result.workspaceName),
        hostname: hostname,
        installationId: installationId,
        pairedAt: now,
      );
      try {
        await WorkspaceRegistrationStore(dataDirectory).write(registration);
      } on Object {
        await _credentialStore.delete(result.workspaceRuntimeId);
        rethrow;
      }
      if (previous != null &&
          previous.workspaceRuntimeId != result.workspaceRuntimeId) {
        await _credentialStore.delete(previous.workspaceRuntimeId);
      }
      if (allowRecovery) {
        await InstallationIdentityStore(dataDirectory)
            .clearRecoveryAuthorization();
      }
      return registration;
    } finally {
      client.close();
    }
  }
}
