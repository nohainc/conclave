import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'profile_lab_auth.dart';
import 'profile_lab_cloud_config.dart';
import 'models/profile_admin_read_models.dart';

export 'models/profile_admin_read_models.dart';

/// HTTP Client for Conclave Cloud Profile Admin API endpoints.
///
/// Profile Lab communicates exclusively via this authenticated API client
/// and never connects directly to Cloudflare D1.
class ProfileAdminApiClient {
  ProfileAdminApiClient({
    required String baseUrl,
    this.session,
    HttpClient? httpClient,
  })  : baseUrl = ProfileLabCloudConfig.normalizeOrigin(baseUrl),
        _http = httpClient ?? HttpClient();

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
    Map<String, String>? headers,
  }) async {
    final request =
        await _http.openUrl(method, uri).timeout(const Duration(seconds: 15));
    if (session != null && !session!.isExpired) {
      request.headers.set(
          HttpHeaders.authorizationHeader, 'Bearer ${session!.credential}');
    }
    headers?.forEach(request.headers.set);
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
      if (response.statusCode == HttpStatus.notFound) {
        throw ProfileAdminNotFoundException(errorMessage);
      }
      throw StateError(errorMessage);
    }
    return decoded;
  }

  /// Lists all logical workers across all lifecycle states, stages, and visibility.
  Future<List<ProfileLabWorkerReadModel>> fetchWorkerCatalog() async {
    final result = await _request('GET', _api('/api/admin/workers/catalog'));
    if (result is Map && result['workers'] is List) {
      return _readModels(
        result['workers'] as List,
        ProfileLabWorkerReadModel.fromJson,
        'workers',
      );
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
  Future<List<ProfileLabDefinitionReadModel>> fetchDefinitions() async {
    final result =
        await _request('GET', _api('/api/admin/tool-profiles/definitions'));
    if (result is Map && result['definitions'] is List) {
      return _readModels(
        result['definitions'] as List,
        ProfileLabDefinitionReadModel.fromJson,
        'definitions',
      );
    }
    return [];
  }

  /// Retrieves a single Profile definition by ID.
  Future<ProfileLabDefinitionReadModel> fetchDefinition(
      String profileDefinitionId) async {
    final result = await _request(
      'GET',
      _api(
          '/api/admin/tool-profiles/definitions/${Uri.encodeComponent(profileDefinitionId)}'),
    );
    if (result is Map) {
      return ProfileLabDefinitionReadModel.fromJson(
          Map<String, dynamic>.from(result));
    }
    throw StateError('Invalid definition response');
  }

  /// Lists all releases for a specific Profile definition.
  Future<List<ProfileLabReleaseReadModel>> fetchReleases(
      String profileDefinitionId) async {
    final result = await _request(
      'GET',
      _api(
          '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/releases'),
    );
    if (result is Map && result['releases'] is List) {
      return _readModels(
        result['releases'] as List,
        ProfileLabReleaseReadModel.fromJson,
        'releases',
      );
    }
    return [];
  }

  /// Retrieves a single release by version with parsed payload.
  Future<ProfileLabReleaseReadModel> fetchRelease(
      String profileDefinitionId, int releaseVersion) async {
    final result = await _request(
      'GET',
      _api(
          '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/releases/$releaseVersion'),
    );
    if (result is Map) {
      return ProfileLabReleaseReadModel.fromJson(
          Map<String, dynamic>.from(result));
    }
    throw StateError('Invalid release response');
  }

  /// Lists channel pointers globally or scoped to a definition.
  Future<List<ProfileLabChannelPointerReadModel>> fetchChannelPointers(
      [String? profileDefinitionId]) async {
    final path = profileDefinitionId != null
        ? '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/channels'
        : '/api/admin/tool-profiles/channels';
    final result = await _request('GET', _api(path));
    if (result is Map && result['channels'] is List) {
      return _readModels(
        result['channels'] as List,
        ProfileLabChannelPointerReadModel.fromJson,
        'channels',
      );
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
  Future<List<ProfileLabEvidenceReadModel>> fetchReleaseEvidence(
    String profileDefinitionId,
    int releaseVersion,
  ) async {
    final result = await _request(
      'GET',
      _api(
          '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/releases/$releaseVersion/evidence'),
    );
    if (result is Map && result['evidence'] is List) {
      return _readModels(
        result['evidence'] as List,
        ProfileLabEvidenceReadModel.fromJson,
        'evidence',
      );
    }
    return [];
  }

  /// Submits one complete sandbox acceptance contract as immutable Cloud evidence.
  Future<Map<String, dynamic>> submitReleaseEvidence({
    required String profileDefinitionId,
    required int releaseVersion,
    required Map<String, Object?> evidence,
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
    throw StateError('Invalid submit evidence response');
  }

  /// Lists audit events globally or scoped to a definition.
  Future<List<ProfileLabAuditEventReadModel>> fetchAudit(
      [String? profileDefinitionId]) async {
    final path = profileDefinitionId != null
        ? '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/audit'
        : '/api/admin/tool-profiles/audit';
    final result = await _request('GET', _api(path));
    if (result is Map && result['events'] is List) {
      return _readModels(
        result['events'] as List,
        ProfileLabAuditEventReadModel.fromJson,
        'events',
      );
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
      headers: expectedBaseDigest == null
          ? null
          : {HttpHeaders.ifMatchHeader: '"$expectedBaseDigest"'},
      body: {'profile': profile},
    );
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    throw StateError('Invalid update draft response');
  }

  /// Creates a new mutable Cloud draft release.
  Future<Map<String, dynamic>> createDraftRelease({
    required String profileDefinitionId,
    required int releaseVersion,
    required Map<String, dynamic> profile,
  }) async {
    final result = await _request(
      'POST',
      _api(
          '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/releases'),
      body: {'releaseVersion': releaseVersion, 'profile': profile},
    );
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    throw StateError('Invalid create draft response');
  }

  /// Requests Cloud publication and Ed25519 signing for a draft release version.
  /// Signing occurs in the controlled Cloud signing service; Profile Lab does
  /// not act as a key custodian.
  Future<Map<String, dynamic>> publishRelease({
    required String profileDefinitionId,
    required int releaseVersion,
    required String qualificationEvidenceId,
  }) async {
    final result = await _request(
      'POST',
      _api(
          '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/releases/$releaseVersion/publish'),
      body: {'qualificationEvidenceId': qualificationEvidenceId},
    );
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    throw StateError('Invalid publish response');
  }

  /// Submits complete local Engine qualification for a mutable Cloud draft.
  Future<Map<String, dynamic>> submitLocalQualification({
    required String profileDefinitionId,
    required int releaseVersion,
    required Map<String, Object?> evidence,
  }) async {
    final result = await _request(
      'POST',
      _api(
        '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/releases/$releaseVersion/qualification',
      ),
      body: {'evidence': evidence},
    );
    if (result is Map) return Map<String, dynamic>.from(result);
    throw StateError('Invalid local qualification response');
  }

  /// Checks that Cloud's configured Profile signer is trusted and not revoked.
  Future<ProfileLabSigningPreflightReadModel> checkSigningPreflight() async {
    final result = await _request(
      'GET',
      _api('/api/admin/tool-profiles/signing-preflight'),
    );
    if (result is Map) {
      return ProfileLabSigningPreflightReadModel.fromJson(
          Map<String, dynamic>.from(result));
    }
    throw StateError('Invalid signing preflight response');
  }

  /// Reads Cloud's current release signing key and Profile revocations.
  Future<ProfileLabReleaseTrustReadModel> fetchReleaseTrust() async {
    final result = await _request('GET', _api('/api/release-trust'));
    if (result is Map) {
      return ProfileLabReleaseTrustReadModel.fromJson(
          Map<String, dynamic>.from(result));
    }
    throw StateError('Invalid release trust response');
  }

  /// Promotes a published release. Stable promotion must reference evidence
  /// that was submitted and accepted by Cloud in a separate request.
  Future<Map<String, dynamic>> promoteRelease({
    required String profileDefinitionId,
    required int releaseVersion,
    required String channel,
    String? acceptanceEvidenceId,
  }) async {
    final normalizedChannel = channel.toLowerCase();
    if (!{'beta', 'stable'}.contains(normalizedChannel)) {
      throw StateError(
        'Profile Lab can only promote releases to beta or stable.',
      );
    }
    if (normalizedChannel == 'stable' &&
        (acceptanceEvidenceId == null || acceptanceEvidenceId.trim().isEmpty)) {
      throw StateError('Stable promotion requires a stored Cloud evidence ID.');
    }
    if (normalizedChannel != 'stable' && acceptanceEvidenceId != null) {
      throw StateError(
          'Only stable promotion may reference acceptance evidence.');
    }
    final result = await _request(
      'POST',
      _api(
          '/api/admin/tool-profiles/${Uri.encodeComponent(profileDefinitionId)}/releases/$releaseVersion/promote'),
      body: {
        'channel': normalizedChannel,
        if (acceptanceEvidenceId != null)
          'acceptanceEvidenceId': acceptanceEvidenceId,
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
  Future<List<ProfileLabWorkspaceChannelReadModel>>
      listWorkspaceChannels() async {
    final result = await _request('GET', _api('/api/admin/workspace-channels'));
    if (result is Map && result['workspaces'] is List) {
      return _readModels(
        result['workspaces'] as List,
        ProfileLabWorkspaceChannelReadModel.fromJson,
        'workspaces',
      );
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

class ProfileAdminNotFoundException extends StateError {
  ProfileAdminNotFoundException(super.message);
}

List<T> _readModels<T extends ProfileAdminReadModel>(
  List values,
  T Function(Map<String, dynamic>) parse,
  String field,
) {
  return List<T>.unmodifiable(values.map((value) {
    if (value is! Map) {
      throw StateError('Invalid $field response item');
    }
    return parse(Map<String, dynamic>.from(value));
  }));
}
