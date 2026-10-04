/// Typed read models returned by the Profile Admin API.
///
/// Profile payloads remain open JSON because the Tool Profile schema is
/// versioned independently. The surrounding Cloud records expose typed
/// identity and lifecycle fields while retaining unknown response fields for
/// forward compatibility with the UI.
abstract class ProfileAdminReadModel {
  ProfileAdminReadModel(Map<String, dynamic> json)
      : _json = Map<String, dynamic>.unmodifiable(json);

  final Map<String, dynamic> _json;

  Map<String, dynamic> toJson() => Map<String, dynamic>.from(_json);

  /// Compatibility accessor for existing presentation code during migration
  /// to direct typed property access.
  Object? operator [](String key) => _json[key];
}

class ProfileLabWorkerReadModel extends ProfileAdminReadModel {
  ProfileLabWorkerReadModel.fromJson(super.json)
      : workerTypeId = _string(json, 'workerTypeId') ?? '',
        profileDefinitionId = _string(json, 'profileDefinitionId'),
        displayName = _string(json, 'displayName') ?? '',
        providerToolName = _string(json, 'providerToolName') ?? '',
        releaseStage = _string(json, 'releaseStage') ?? 'draft',
        capabilities = _stringList(json, 'capabilities'),
        sortOrder = _int(json, 'sortOrder');

  final String workerTypeId;
  final String? profileDefinitionId;
  final String displayName;
  final String providerToolName;
  final String releaseStage;
  final List<String> capabilities;
  final int? sortOrder;
}

class ProfileLabDefinitionReadModel extends ProfileAdminReadModel {
  ProfileLabDefinitionReadModel.fromJson(super.json)
      : profileDefinitionId =
            _string(json, 'profileDefinitionId') ?? _string(json, 'id') ?? '',
        displayName = _string(json, 'displayName') ?? '',
        description = _string(json, 'description'),
        status = _string(json, 'status');

  final String profileDefinitionId;
  final String displayName;
  final String? description;
  final String? status;
}

class ProfileLabReleaseReadModel extends ProfileAdminReadModel {
  ProfileLabReleaseReadModel.fromJson(super.json)
      : profileDefinitionId = _string(json, 'profileDefinitionId') ?? '',
        releaseVersion = _int(json, 'releaseVersion') ?? 0,
        lifecycleState =
            _string(json, 'lifecycleState') ?? _string(json, 'status') ?? '',
        payloadDigest = _string(json, 'payloadDigest'),
        publishedAt = _string(json, 'publishedAt'),
        profile = _object(json, 'profile');

  final String profileDefinitionId;
  final int releaseVersion;
  final String lifecycleState;
  final String? payloadDigest;
  final String? publishedAt;
  final Map<String, dynamic>? profile;
}

class ProfileLabEvidenceReadModel extends ProfileAdminReadModel {
  ProfileLabEvidenceReadModel.fromJson(super.json)
      : id = _string(json, 'id') ?? '',
        profileDefinitionId = _string(json, 'profileDefinitionId'),
        releaseVersion = _int(json, 'releaseVersion'),
        status = _string(json, 'status') ?? '',
        payloadDigest = _string(json, 'payloadDigest');

  final String id;
  final String? profileDefinitionId;
  final int? releaseVersion;
  final String status;
  final String? payloadDigest;
}

class ProfileLabAuditEventReadModel extends ProfileAdminReadModel {
  ProfileLabAuditEventReadModel.fromJson(super.json)
      : id = _string(json, 'id') ?? '',
        action = _string(json, 'action') ?? '',
        actor = _string(json, 'actor'),
        createdAt = _string(json, 'createdAt') ?? _string(json, 'timestamp');

  final String id;
  final String action;
  final String? actor;
  final String? createdAt;
}

class ProfileLabWorkspaceChannelReadModel extends ProfileAdminReadModel {
  ProfileLabWorkspaceChannelReadModel.fromJson(super.json)
      : workspaceId = _string(json, 'workspaceId') ?? _string(json, 'id') ?? '',
        name = _string(json, 'name') ?? '',
        channel = _string(json, 'channel') ?? '',
        hostname = _string(json, 'hostname'),
        platform = _string(json, 'platform');

  final String workspaceId;
  final String name;
  final String channel;
  final String? hostname;
  final String? platform;
}

class ProfileLabChannelPointerReadModel extends ProfileAdminReadModel {
  ProfileLabChannelPointerReadModel.fromJson(super.json)
      : profileDefinitionId = _string(json, 'profileDefinitionId') ?? '',
        channel = _string(json, 'channel') ?? '',
        releaseVersion = _int(json, 'releaseVersion');

  final String profileDefinitionId;
  final String channel;
  final int? releaseVersion;
}

class ProfileLabSigningPreflightReadModel extends ProfileAdminReadModel {
  ProfileLabSigningPreflightReadModel.fromJson(super.json)
      : ready = json['ready'] == true,
        publisher = _string(json, 'publisher'),
        signingKeyId = _string(json, 'signingKeyId'),
        issues = _stringList(json, 'issues');

  final bool ready;
  final String? publisher;
  final String? signingKeyId;
  final List<String> issues;
}

class ProfileLabRevokedToolProfileReadModel extends ProfileAdminReadModel {
  ProfileLabRevokedToolProfileReadModel.fromJson(super.json)
      : profileDefinitionId = _string(json, 'profileDefinitionId') ?? '',
        releaseVersion = _int(json, 'releaseVersion') ?? 0,
        payloadDigest = _string(json, 'payloadDigest') ?? '';

  final String profileDefinitionId;
  final int releaseVersion;
  final String payloadDigest;
}

class ProfileLabReleaseTrustReadModel extends ProfileAdminReadModel {
  ProfileLabReleaseTrustReadModel.fromJson(super.json)
      : revokedKeyIds = _strictStringList(json['revokedKeyIds']),
        revokedToolProfiles = _strictReadModelList(
          json['revokedToolProfiles'],
          ProfileLabRevokedToolProfileReadModel.fromJson,
        );

  final List<String> revokedKeyIds;
  final List<ProfileLabRevokedToolProfileReadModel> revokedToolProfiles;
}

String? _string(Map<String, dynamic> json, String key) =>
    json[key] is String ? json[key] as String : null;

int? _int(Map<String, dynamic> json, String key) =>
    json[key] is int ? json[key] as int : null;

Map<String, dynamic>? _object(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is Map ? Map<String, dynamic>.from(value) : null;
}

List<String> _stringList(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) return const [];
  return List<String>.unmodifiable(value.whereType<String>());
}

List<String> _strictStringList(Object? value) {
  if (value is! List || value.any((item) => item is! String)) {
    throw const FormatException('Release trust key revocations are invalid.');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

List<T> _strictReadModelList<T>(
  Object? value,
  T Function(Map<String, dynamic>) parse,
) {
  if (value is! List || value.any((item) => item is! Map)) {
    throw const FormatException(
        'Release trust Profile revocations are invalid.');
  }
  return List<T>.unmodifiable(value.map(
    (item) => parse(Map<String, dynamic>.from(item as Map)),
  ));
}

class ProfileLabAccessReadModel {
  ProfileLabAccessReadModel.fromJson(Map<String, dynamic> json)
      : profilesAdmin = (json['permissions'] as Map?)?['profilesAdmin'] == true,
        releaseManager =
            (json['permissions'] as Map?)?['releaseManager'] == true,
        signerReady = (json['signer'] as Map?)?['ready'] == true,
        draftsOnly = json['releaseMode'] == 'drafts-only';
  final bool profilesAdmin;
  final bool releaseManager;
  final bool signerReady;
  final bool draftsOnly;
}
