/// Typed read models returned by the V9 Profile Admin API.
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
        currentRevision = _int(json, 'currentRevision'),
        currentDigest = _string(json, 'currentDigest'),
        sortOrder = _int(json, 'sortOrder');

  final String workerTypeId;
  final String? profileDefinitionId;
  final String displayName;
  final String providerToolName;
  final int? currentRevision;
  final String? currentDigest;
  final int? sortOrder;
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

class ProfileLabAccessReadModel {
  ProfileLabAccessReadModel.fromJson(Map<String, dynamic> json)
      : profilesAdmin = (json['permissions'] as Map?)?['profilesAdmin'] == true,
        issueSupport = (json['permissions'] as Map?)?['issueSupport'] == true,
        signerReady = (json['signer'] as Map?)?['ready'] == true,
        signerIssues = List<String>.unmodifiable(
            ((json['signer'] as Map?)?['issues'] as List? ?? const [])
                .whereType<String>());
  final bool profilesAdmin;
  final bool issueSupport;
  final bool signerReady;
  final List<String> signerIssues;
}

class ProfileLabIssueReportReadModel extends ProfileAdminReadModel {
  ProfileLabIssueReportReadModel.fromJson(super.json)
      : id = _string(json, 'id') ?? '',
        publicReference = _string(json, 'publicReference') ?? '',
        requestId = _string(json, 'requestId') ?? '',
        assignmentId = _string(json, 'assignmentId'),
        component = _string(json, 'component') ?? '',
        errorCode = _string(json, 'errorCode') ?? '',
        failureStage = _string(json, 'failureStage') ?? '',
        fingerprint = _string(json, 'fingerprint') ?? '',
        status = _string(json, 'status') ?? '',
        diagnosticState = _string(json, 'diagnosticState') ?? '',
        workerTypeId = _string(json, 'workerTypeId'),
        modelId = _string(json, 'modelId'),
        effort = _string(json, 'effort'),
        createdAt = _string(json, 'createdAt') ?? '',
        incidentGroup = _object(json, 'incidentGroup'),
        versions = _object(json, 'versions');

  final String id;
  final String publicReference;
  final String requestId;
  final String? assignmentId;
  final String component;
  final String errorCode;
  final String failureStage;
  final String fingerprint;
  final String status;
  final String diagnosticState;
  final String? workerTypeId;
  final String? modelId;
  final String? effort;
  final String createdAt;
  final Map<String, dynamic>? incidentGroup;
  final Map<String, dynamic>? versions;
}

class ProfileLabIssueReportGroupReadModel extends ProfileAdminReadModel {
  ProfileLabIssueReportGroupReadModel.fromJson(super.json)
      : id = _string(json, 'id') ?? '',
        publicReference = _string(json, 'publicReference') ?? '',
        label = _string(json, 'label') ?? '',
        fingerprint = _string(json, 'fingerprint'),
        reportCount = _int(json, 'reportCount') ?? 0,
        firstOccurrence = _string(json, 'firstOccurrence'),
        lastOccurrence = _string(json, 'lastOccurrence'),
        affectedWorkerTypes = _stringList(json, 'affectedWorkerTypes'),
        affectedProviderVersions =
            _stringList(json, 'affectedProviderVersions'),
        affectedEngineVersions = _stringList(json, 'affectedEngineVersions'),
        affectedProfileVersions = _stringList(json, 'affectedProfileVersions');

  final String id;
  final String publicReference;
  final String label;
  final String? fingerprint;
  final int reportCount;
  final String? firstOccurrence;
  final String? lastOccurrence;
  final List<String> affectedWorkerTypes;
  final List<String> affectedProviderVersions;
  final List<String> affectedEngineVersions;
  final List<String> affectedProfileVersions;
}
