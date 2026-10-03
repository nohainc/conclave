import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'profile_lab_auth.dart';

/// HTTP Client for Conclave Cloud Profile Admin API endpoints.
///
/// Profile Lab communicates exclusively via this authenticated API client
/// and never connects directly to Cloudflare D1.
class ProfileAdminApiClient {
  ProfileAdminApiClient({
    required this.baseUrl,
    this.session,
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient();

  final String baseUrl;
  final ProfileLabSession? session;
  final HttpClient _http;

  Uri _api(String path, [Map<String, String>? queryParams]) {
    final cleanedBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$cleanedBase$path');
    if (queryParams != null && queryParams.isNotEmpty) {
      return uri.replace(queryParameters: queryParams);
    }
    return uri;
  }

  Future<dynamic> _request(
    String method,
    Uri uri, {
    Object? body,
  }) async {
    final request =
        await _http.openUrl(method, uri).timeout(const Duration(seconds: 15));
    if (session != null && !session!.isExpired) {
      request.headers.set(
          HttpHeaders.authorizationHeader, 'Bearer ${session!.credential}');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 15));
    final responseText = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 15));
    dynamic decoded;
    try {
      decoded = jsonDecode(responseText);
    } catch (_) {
      decoded = null;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      String errorMessage = 'Request failed (${response.statusCode})';
      if (decoded is Map && decoded['error'] is String) {
        errorMessage = decoded['error'] as String;
      }
      throw StateError(errorMessage);
    }
    return decoded;
  }

  /// Lists all logical workers across all lifecycle states, stages, and visibility.
  Future<List<Map<String, dynamic>>> fetchWorkerCatalog() async {
    final result = await _request('GET', _api('/api/admin/workers/catalog'));
    if (result is Map && result['workers'] is List) {
      return (result['workers'] as List).cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Atomically registers an approved logical Worker and its initial Profile definition.
  Future<Map<String, dynamic>> createWorker({
    required String workerTypeId,
    required String profileDefinitionId,
    required String displayName,
    required String description,
    required String providerToolName,
    required String releaseStage,
    required List<String> capabilities,
    required int sortOrder,
  }) async {
    final result = await _request(
      'POST',
      _api('/api/admin/workers/catalog'),
      body: {
        'workerTypeId': workerTypeId,
        'profileDefinitionId': profileDefinitionId,
        'displayName': displayName,
        'description': description,
        'providerToolName': providerToolName,
        'releaseStage': releaseStage,
        'capabilities': capabilities,
        'sortOrder': sortOrder,
      },
    );
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    throw StateError('Invalid create worker response');
  }

  /// Lists all Profile definitions with aggregated channel pointers and release counts.
  Future<List<Map<String, dynamic>>> fetchDefinitions() async {
    final result =
        await _request('GET', _api('/api/admin/tool-profiles/definitions'));
    if (result is Map && result['definitions'] is List) {
      return (result['definitions'] as List).cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Retrieves a single Profile definition by ID.
  Future<Map<String, dynamic>> fetchDefinition(
      String profileDefinitionId) async {
    final result = await _request(
      'GET',
      _api(
          '/api/admin/tool-profiles/definitions/${Uri.encodeComponent(profileDefinitionId)}'),
    );
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    throw StateError('Invalid definition response');
  }

  /// Lists all releases for a specific Profile definition.
  Future<List<Map<String, dynamic>>> fetchReleases(
      String profileDefinitionId) async {
    final result = await _request(
      'GET',
      _api(
          '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/releases'),
    );
    if (result is Map && result['releases'] is List) {
      return (result['releases'] as List).cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Retrieves a single release by version with parsed payload.
  Future<Map<String, dynamic>> fetchRelease(
      String profileDefinitionId, int releaseVersion) async {
    final result = await _request(
      'GET',
      _api(
          '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/releases/$releaseVersion'),
    );
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    throw StateError('Invalid release response');
  }

  /// Lists channel pointers globally or scoped to a definition.
  Future<List<Map<String, dynamic>>> fetchChannelPointers(
      [String? profileDefinitionId]) async {
    final path = profileDefinitionId != null
        ? '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/channels'
        : '/api/admin/tool-profiles/channels';
    final result = await _request('GET', _api(path));
    if (result is Map && result['channels'] is List) {
      return (result['channels'] as List).cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Executes safe channel pointer rollback to an earlier release version.
  Future<Map<String, dynamic>> rollbackChannel({
    required String profileDefinitionId,
    required String channel,
    required int targetReleaseVersion,
    String? reason,
  }) async {
    final result = await _request(
      'POST',
      _api(
          '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/channels/${Uri.encodeComponent(channel)}/rollback'),
      body: {
        'targetReleaseVersion': targetReleaseVersion,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      },
    );
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    throw StateError('Invalid rollback response');
  }

  /// Lists acceptance evidence submitted to Cloud for a release version.
  Future<List<Map<String, dynamic>>> fetchReleaseEvidence(
    String profileDefinitionId,
    int releaseVersion,
  ) async {
    final result = await _request(
      'GET',
      _api(
          '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/releases/$releaseVersion/evidence'),
    );
    if (result is Map && result['evidence'] is List) {
      return (result['evidence'] as List).cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Submits verified acceptance evidence bound to the exact release payload digest.
  Future<Map<String, dynamic>> submitReleaseEvidence({
    required String profileDefinitionId,
    required int releaseVersion,
    required Map<String, dynamic> evidence,
  }) async {
    final result = await _request(
      'POST',
      _api(
          '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/releases/$releaseVersion/evidence'),
      body: {'evidence': evidence},
    );
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    throw StateError('Invalid evidence submission response');
  }

  /// Lists audit events globally or scoped to a definition.
  Future<List<Map<String, dynamic>>> fetchAudit(
      [String? profileDefinitionId]) async {
    final path = profileDefinitionId != null
        ? '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/audit'
        : '/api/admin/tool-profiles/audit';
    final result = await _request('GET', _api(path));
    if (result is Map && result['events'] is List) {
      return (result['events'] as List).cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Updates a draft release payload in Cloud with optimistic concurrency protection.
  Future<Map<String, dynamic>> updateDraft({
    required String profileDefinitionId,
    required int releaseVersion,
    required Map<String, dynamic> profile,
    String? expectedBaseDigest,
  }) async {
    final result = await _request(
      'PUT',
      _api(
          '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/releases/$releaseVersion/draft'),
      body: {
        'profile': profile,
        if (expectedBaseDigest != null)
          'expectedBaseDigest': expectedBaseDigest,
      },
    );
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    throw StateError('Invalid update draft response');
  }

  /// Requests Cloud publication and Ed25519 signing for a draft release version.
  /// Signing occurs in the controlled Cloud signing service; Profile Lab does
  /// not act as a key custodian.
  Future<Map<String, dynamic>> publishRelease({
    required String profileDefinitionId,
    required int releaseVersion,
    String? signature,
    String? signingKeyId,
  }) async {
    final result = await _request(
      'POST',
      _api(
          '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/releases/$releaseVersion/publish'),
      body: {
        if (signature != null) 'signature': signature,
        if (signingKeyId != null) 'signingKeyId': signingKeyId,
      },
    );
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    throw StateError('Invalid publish response');
  }

  /// Promotes a published release into beta or stable channel.
  Future<Map<String, dynamic>> promoteRelease({
    required String profileDefinitionId,
    required int releaseVersion,
    required String channel,
    Map<String, dynamic>? acceptanceEvidence,
  }) async {
    final result = await _request(
      'POST',
      _api(
          '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/releases/$releaseVersion/promote'),
      body: {
        'channel': channel,
        if (acceptanceEvidence != null)
          'acceptanceEvidence': acceptanceEvidence,
      },
    );
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    throw StateError('Invalid promote response');
  }

  /// Retires or revokes a release version.
  Future<Map<String, dynamic>> changeLifecycle({
    required String profileDefinitionId,
    required int releaseVersion,
    required String lifecycle,
    required String reason,
  }) async {
    final result = await _request(
      'POST',
      _api(
          '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/releases/$releaseVersion/$lifecycle'),
      body: {'reason': reason},
    );
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    throw StateError('Invalid lifecycle change response');
  }

  /// Lists all registered development/test workspaces with their tool profile channel assignments.
  Future<List<Map<String, dynamic>>> listWorkspaceChannels() async {
    final result = await _request('GET', _api('/api/admin/workspace-channels'));
    if (result is Map && result['workspaces'] is List) {
      return (result['workspaces'] as List).cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Sets the tool profile rollout channel for a given workspace.
  Future<Map<String, dynamic>> setWorkspaceChannel({
    required String workspaceId,
    required String channel,
  }) async {
    final result = await _request(
      'PATCH',
      _api(
          '/api/workspaces/${Uri.encodeComponent(workspaceId)}/tool-profile-channel'),
      body: {'channel': channel},
    );
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    throw StateError('Invalid set workspace channel response');
  }

  void close() => _http.close(force: true);
}
