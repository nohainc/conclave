import 'package:conclave_protocol/conclave_protocol.dart';

/// Product capabilities only; no provider invocation or credential data.
class AxWorkerEffortOptions {
  const AxWorkerEffortOptions(
      {required this.supported, required this.values, this.defaultValue});
  final bool supported;
  final List<String> values;
  final String? defaultValue;
  factory AxWorkerEffortOptions.fromJson(Map<String, dynamic> json) =>
      AxWorkerEffortOptions(
        supported: json['supported'] == true,
        values: List<String>.unmodifiable(
            (json['values'] as List? ?? const []).whereType<String>()),
        defaultValue: json['defaultValue'] as String?,
      );
}

class AxWorkerModelOption {
  const AxWorkerModelOption(
      {required this.id,
      required this.name,
      required this.effort,
      this.badge,
      this.description,
      this.status = 'listed',
      this.selectionMode = 'separate'});
  final String id;
  final String name;
  final String? badge;
  final String? description;
  final AxWorkerEffortOptions effort;
  final String status;
  final String selectionMode;
  factory AxWorkerModelOption.fromJson(Map<String, dynamic> json,
          {int schemaVersion = 1}) =>
      AxWorkerModelOption(
        id: json['id'] as String,
        name: json['name'] as String,
        badge: json['badge'] as String?,
        description: json['description'] as String?,
        status: schemaVersion == 2 ? json['status'] as String : 'listed',
        selectionMode:
            schemaVersion == 2 ? json['selectionMode'] as String : 'separate',
        effort: AxWorkerEffortOptions.fromJson(schemaVersion == 2
            ? {
                'supported':
                    (json['efforts'] as List? ?? const []).isNotEmpty &&
                        json['status'] != 'unavailable',
                'values': json['efforts'] ?? const [],
                'defaultValue': json['defaultEffort'],
              }
            : Map<String, dynamic>.from(json['effort'] as Map)),
      );
}

class AxWorkerExecutionOptions {
  const AxWorkerExecutionOptions(
      {required this.modelSelectionSupported,
      required this.modelDiscovery,
      required this.allowsCustomModel,
      required this.allowedModelIds,
      required this.models,
      required this.modelSwitchSupported,
      required this.effort,
      this.defaultModelId,
      this.catalogRevision,
      this.catalogStale = false});
  final bool modelSelectionSupported;
  final String modelDiscovery;
  final bool allowsCustomModel;
  final List<String> allowedModelIds;
  final String? defaultModelId;
  final String? catalogRevision;
  final bool catalogStale;
  final List<AxWorkerModelOption> models;
  final bool modelSwitchSupported;
  final AxWorkerEffortOptions effort;
  Map<String, dynamic> toJson() => {
        'schemaVersion': catalogRevision == null ? 1 : 2,
        if (catalogRevision != null) 'catalogRevision': catalogRevision,
        if (catalogRevision != null && catalogStale) 'catalogStale': true,
        'models': {
          'supported': modelSelectionSupported,
          'discovery': modelDiscovery,
          'allowsCustomModel': allowsCustomModel,
          'allowedModelIds': allowedModelIds,
          'defaultModelId': defaultModelId,
          'options': [
            for (final model in models)
              {
                'id': model.id,
                'name': model.name,
                if (model.badge != null) 'badge': model.badge,
                if (model.description != null) 'description': model.description,
                if (catalogRevision != null) ...{
                  'efforts': model.effort.values,
                  'defaultEffort': model.effort.defaultValue,
                  'selectionMode': model.selectionMode,
                  'status': model.status,
                } else
                  'effort': {
                    'supported': model.effort.supported,
                    'values': model.effort.values,
                    'defaultValue': model.effort.defaultValue
                  },
              }
          ],
        },
        'modelSwitch': {'supported': modelSwitchSupported},
        'effort': {
          'supported': effort.supported,
          'values': effort.values,
          'defaultValue': effort.defaultValue
        },
      };

  AxWorkerEffortOptions effortsForModel(String? modelId) {
    for (final model in models) {
      if (model.id == (modelId ?? defaultModelId)) return model.effort;
    }
    return effort;
  }

  /// Retain saved choices until the user replaces them. Capability validation
  /// and deliberate model-change reconciliation live in the shared contract.
  ({String? model, String? effort}) reconcileSelection(
      {String? model, String? effort}) {
    final value = ExecutionSelection(model: model, effort: effort).normalized();
    return (model: value.model, effort: value.effort);
  }

  factory AxWorkerExecutionOptions.fromJson(Map<String, dynamic> json) {
    if (!const {1, 2}.contains(json['schemaVersion'])) {
      throw const FormatException('Unsupported Worker execution options');
    }
    final version = json['schemaVersion'] as int;
    if (json['catalogStale'] != null && json['catalogStale'] is! bool) {
      throw const FormatException('Invalid catalog stale state');
    }
    if (version == 2 &&
        (json['catalogRevision'] is! String ||
            !RegExp(r'^[0-9a-f]{64}$')
                .hasMatch(json['catalogRevision'] as String))) {
      throw const FormatException('Invalid catalog revision');
    }
    final models = Map<String, dynamic>.from(json['models'] as Map);
    final ids = <String>{};
    for (final raw in models['options'] as List? ?? const []) {
      final entry = Map<String, dynamic>.from(raw as Map);
      if (!ids.add(entry['id'] as String)) {
        throw const FormatException('Duplicate model IDs');
      }
      if (version == 2) {
        final efforts = (entry['efforts'] as List? ?? const []).cast<String>();
        if (efforts.length > 16 ||
            efforts.toSet().length != efforts.length ||
            efforts.any((value) =>
                !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$')
                    .hasMatch(value)) ||
            (entry['defaultEffort'] != null &&
                !efforts.contains(entry['defaultEffort'])) ||
            !const {'separate', 'combined'}.contains(entry['selectionMode']) ||
            !const {'listed', 'verified', 'unavailable'}
                .contains(entry['status'])) {
          throw const FormatException('Invalid model selection metadata');
        }
      }
    }
    return AxWorkerExecutionOptions(
      modelSelectionSupported: models['supported'] == true,
      modelDiscovery: models['discovery'] as String,
      allowsCustomModel: models['allowsCustomModel'] == true,
      allowedModelIds: List<String>.unmodifiable(
          (models['allowedModelIds'] as List? ?? const []).whereType<String>()),
      defaultModelId: models['defaultModelId'] as String?,
      catalogRevision: json['catalogRevision'] as String?,
      catalogStale: json['catalogStale'] == true,
      models: List<AxWorkerModelOption>.unmodifiable(
          (models['options'] as List? ?? const []).whereType<Map>().map(
              (entry) => AxWorkerModelOption.fromJson(
                  Map<String, dynamic>.from(entry),
                  schemaVersion: version))),
      modelSwitchSupported: (json['modelSwitch'] as Map?)?['supported'] == true,
      effort: AxWorkerEffortOptions.fromJson(
          Map<String, dynamic>.from(json['effort'] as Map)),
    );
  }
}
