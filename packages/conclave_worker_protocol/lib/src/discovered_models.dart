/// Bounded public metadata. No provider commands, credentials or paths.
final class DiscoveredModel {
  DiscoveredModel({
    required this.id,
    required this.name,
    this.status = 'listed',
    Iterable<String> supportedReasoningEfforts = const [],
    this.defaultReasoningEffort,
  }) : supportedReasoningEfforts = List.unmodifiable(
          supportedReasoningEfforts,
        ) {
    final efforts = supportedReasoningEfforts;
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(id) ||
        name.isEmpty ||
        name.length > 256 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
        !const {'listed', 'verified', 'unavailable'}.contains(status) ||
        efforts.length > 16 ||
        efforts.toSet().length != efforts.length ||
        efforts.any((effort) =>
            !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$').hasMatch(effort)) ||
        (defaultReasoningEffort != null &&
            !efforts.contains(defaultReasoningEffort))) {
      throw const FormatException('Invalid discovered model');
    }
  }
  final String id;
  final String name;
  final String status;
  final List<String> supportedReasoningEfforts;
  final String? defaultReasoningEffort;
  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'status': status,
        if (supportedReasoningEfforts.isNotEmpty)
          'supportedReasoningEfforts': supportedReasoningEfforts,
        if (defaultReasoningEffort != null)
          'defaultReasoningEffort': defaultReasoningEffort,
      };
  factory DiscoveredModel.fromJson(Map<String, Object?> value) {
    if (value.keys.any((k) => !const {
              'id',
              'name',
              'status',
              'supportedReasoningEfforts',
              'defaultReasoningEffort'
            }.contains(k)) ||
        value['id'] is! String ||
        value['name'] is! String ||
        value['status'] is! String ||
        (value['supportedReasoningEfforts'] != null &&
            (value['supportedReasoningEfforts'] is! List ||
                (value['supportedReasoningEfforts'] as List)
                    .any((effort) => effort is! String))) ||
        (value['defaultReasoningEffort'] != null &&
            value['defaultReasoningEffort'] is! String)) {
      throw const FormatException('Invalid discovered model');
    }
    return DiscoveredModel(
        id: value['id'] as String,
        name: value['name'] as String,
        status: value['status'] as String,
        supportedReasoningEfforts:
            ((value['supportedReasoningEfforts'] as List?) ?? const [])
                .cast<String>(),
        defaultReasoningEffort: value['defaultReasoningEffort'] as String?);
  }
}

final class DiscoveredModelCatalog {
  DiscoveredModelCatalog(
      {required this.profileDigest,
      required this.providerToolVersion,
      required this.discoveredAt,
      required Iterable<DiscoveredModel> models})
      : models = List.unmodifiable(models) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(profileDigest) ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9.+_-]{0,127}$')
            .hasMatch(providerToolVersion) ||
        discoveredAt.length > 40 ||
        !discoveredAt.contains('T') ||
        !discoveredAt.endsWith('Z') ||
        DateTime.tryParse(discoveredAt) == null ||
        this.models.length > 128 ||
        this.models.map((m) => m.id).toSet().length != this.models.length) {
      throw const FormatException('Invalid discovered model catalog');
    }
  }
  final String profileDigest;
  final String providerToolVersion;
  final String discoveredAt;
  final List<DiscoveredModel> models;
  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'profileDigest': profileDigest,
        'providerToolVersion': providerToolVersion,
        'discoveredAt': discoveredAt,
        'models': models.map((m) => m.toJson()).toList()
      };
  factory DiscoveredModelCatalog.fromJson(Map<String, Object?> value) {
    if (value.keys.any((k) => !const {
              'schemaVersion',
              'profileDigest',
              'providerToolVersion',
              'discoveredAt',
              'models'
            }.contains(k)) ||
        value['schemaVersion'] != 1 ||
        value['profileDigest'] is! String ||
        value['providerToolVersion'] is! String ||
        value['discoveredAt'] is! String ||
        value['models'] is! List)
      throw const FormatException('Invalid model catalog');
    return DiscoveredModelCatalog(
        profileDigest: value['profileDigest'] as String,
        providerToolVersion: value['providerToolVersion'] as String,
        discoveredAt: value['discoveredAt'] as String,
        models: (value['models'] as List).map((v) =>
            DiscoveredModel.fromJson(Map<String, Object?>.from(v as Map))));
  }
}
