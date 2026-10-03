/// Cloud-owned logical Worker metadata. Local readiness and installed Profile
/// state belong to Workspace inventory and are intentionally absent.
class WorkerDescriptor {
  const WorkerDescriptor({
    required this.workerTypeId,
    required this.displayName,
    required this.description,
    required this.engineFamily,
    required this.capabilities,
    required this.profileDefinitionId,
    required this.providerToolName,
    required this.releaseStage,
    required this.visibilityState,
    required this.sortOrder,
  });

  final String workerTypeId;
  final String displayName;
  final String description;
  final String engineFamily;
  final List<String> capabilities;
  final String profileDefinitionId;
  final String providerToolName;
  final String releaseStage;
  final String visibilityState;
  final int sortOrder;

  factory WorkerDescriptor.fromJson(Map<String, Object?> json) {
    const fields = {
      'workerTypeId',
      'displayName',
      'description',
      'engineFamily',
      'capabilities',
      'profileDefinitionId',
      'providerToolName',
      'releaseStage',
      'visibilityState',
      'sortOrder',
    };
    final workerTypeId = json['workerTypeId'];
    final displayName = json['displayName'];
    final description = json['description'];
    final engineFamily = json['engineFamily'];
    final capabilities = json['capabilities'];
    final profileDefinitionId = json['profileDefinitionId'];
    final providerToolName = json['providerToolName'];
    final releaseStage = json['releaseStage'];
    final visibilityState = json['visibilityState'];
    final sortOrder = json['sortOrder'];
    if (json.keys.any((key) => !fields.contains(key)) ||
        workerTypeId is! String ||
        !_identifier.hasMatch(workerTypeId) ||
        workerTypeId.length > 96 ||
        displayName is! String ||
        displayName.trim().isEmpty ||
        displayName.length > 128 ||
        description is! String ||
        description.length > 500 ||
        engineFamily != 'cli' ||
        capabilities is! List ||
        capabilities.length > 32 ||
        capabilities.any((value) =>
            value is! String ||
            value.length > 64 ||
            !_capabilities.contains(value)) ||
        capabilities.toSet().length != capabilities.length ||
        profileDefinitionId is! String ||
        !_identifier.hasMatch(profileDefinitionId) ||
        profileDefinitionId.length > 96 ||
        providerToolName is! String ||
        providerToolName.trim().isEmpty ||
        providerToolName.length > 128 ||
        !const {'testing', 'beta', 'stable'}.contains(releaseStage) ||
        !const {'hidden', 'visible'}.contains(visibilityState) ||
        sortOrder is! int ||
        sortOrder < 0 ||
        sortOrder > 10000) {
      throw const FormatException('Worker descriptor is invalid');
    }
    return WorkerDescriptor(
      workerTypeId: workerTypeId,
      displayName: displayName,
      description: description,
      engineFamily: engineFamily as String,
      capabilities: List.unmodifiable(capabilities.cast<String>()),
      profileDefinitionId: profileDefinitionId,
      providerToolName: providerToolName,
      releaseStage: releaseStage as String,
      visibilityState: visibilityState as String,
      sortOrder: sortOrder,
    );
  }

  Map<String, Object?> toJson() => {
        'workerTypeId': workerTypeId,
        'displayName': displayName,
        'description': description,
        'engineFamily': engineFamily,
        'capabilities': capabilities,
        'profileDefinitionId': profileDefinitionId,
        'providerToolName': providerToolName,
        'releaseStage': releaseStage,
        'visibilityState': visibilityState,
        'sortOrder': sortOrder,
      };
}

const _capabilities = {
  'text',
  'local_file',
  'workstream_read',
  'workstream_write',
  'durable_session',
  'image',
  'audio',
  'video',
};

final _identifier = RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$');
