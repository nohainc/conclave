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
      this.description});
  final String id;
  final String name;
  final String? badge;
  final String? description;
  final AxWorkerEffortOptions effort;
  factory AxWorkerModelOption.fromJson(Map<String, dynamic> json) =>
      AxWorkerModelOption(
        id: json['id'] as String,
        name: json['name'] as String,
        badge: json['badge'] as String?,
        description: json['description'] as String?,
        effort: AxWorkerEffortOptions.fromJson(
            Map<String, dynamic>.from(json['effort'] as Map)),
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
      this.defaultModelId});
  final bool modelSelectionSupported;
  final String modelDiscovery;
  final bool allowsCustomModel;
  final List<String> allowedModelIds;
  final String? defaultModelId;
  final List<AxWorkerModelOption> models;
  final bool modelSwitchSupported;
  final AxWorkerEffortOptions effort;
  AxWorkerEffortOptions effortsForModel(String? modelId) {
    for (final model in models) {
      if (model.id == (modelId ?? defaultModelId)) return model.effort;
    }
    return effort;
  }

  /// Reconcile next-turn overrides without replacing Default with an explicit
  /// value. Provider defaults remain the Profile/Engine's responsibility.
  ({String? model, String? effort}) reconcileSelection(
      {String? model, String? effort}) {
    final selectedModel = model?.trim();
    final validModel = selectedModel != null &&
            selectedModel.isNotEmpty &&
            modelSelectionSupported &&
            (allowedModelIds.isEmpty ||
                allowedModelIds.contains(selectedModel)) &&
            (allowsCustomModel ||
                models.any((item) => item.id == selectedModel))
        ? selectedModel
        : null;
    final capabilities = effortsForModel(validModel);
    final selectedEffort = effort?.trim();
    return (
      model: validModel,
      effort:
          capabilities.supported && capabilities.values.contains(selectedEffort)
              ? selectedEffort
              : null,
    );
  }

  factory AxWorkerExecutionOptions.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported Worker execution options');
    }
    final models = Map<String, dynamic>.from(json['models'] as Map);
    return AxWorkerExecutionOptions(
      modelSelectionSupported: models['supported'] == true,
      modelDiscovery: models['discovery'] as String,
      allowsCustomModel: models['allowsCustomModel'] == true,
      allowedModelIds: List<String>.unmodifiable(
          (models['allowedModelIds'] as List? ?? const []).whereType<String>()),
      defaultModelId: models['defaultModelId'] as String?,
      models: List<AxWorkerModelOption>.unmodifiable((models['options']
                  as List? ??
              const [])
          .whereType<Map>()
          .map((entry) =>
              AxWorkerModelOption.fromJson(Map<String, dynamic>.from(entry)))),
      modelSwitchSupported: (json['modelSwitch'] as Map?)?['supported'] == true,
      effort: AxWorkerEffortOptions.fromJson(
          Map<String, dynamic>.from(json['effort'] as Map)),
    );
  }
}
