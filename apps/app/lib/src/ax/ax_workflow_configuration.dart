/// Auto/inheritance is represented by null and omitted from the wire payload.
class AxWorkflowSelection {
  const AxWorkflowSelection({this.worker, this.model, this.effort});
  final String? worker, model, effort;
  factory AxWorkflowSelection.fromJson(Map<String, dynamic> json) =>
      AxWorkflowSelection(
          worker: json['worker'] as String?,
          model: json['model'] as String?,
          effort: json['effort'] as String?);
  Map<String, dynamic> toJson() => {
        if (worker != null) 'worker': worker,
        if (model != null) 'model': model,
        if (effort != null) 'effort': effort,
      };
  AxWorkflowSelection overlay(AxWorkflowSelection override) =>
      AxWorkflowSelection(
          worker: override.worker ?? worker,
          model: override.model ?? model,
          effort: override.effort ?? effort);
}

class AxUserWorkflowConfiguration {
  AxUserWorkflowConfiguration({
    required this.workflowId,
    this.enabled = true,
    this.defaults = const AxWorkflowSelection(),
    Map<String, AxWorkflowSelection> stepOverrides = const {},
  }) : stepOverrides = Map.unmodifiable(stepOverrides);
  final String workflowId;
  final bool enabled;
  final AxWorkflowSelection defaults;
  final Map<String, AxWorkflowSelection> stepOverrides;
  factory AxUserWorkflowConfiguration.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported workflow configuration version');
    }
    return AxUserWorkflowConfiguration(
      workflowId: json['workflowId'] as String,
      enabled: json['enabled'] as bool,
      defaults: AxWorkflowSelection.fromJson(
          Map<String, dynamic>.from(json['defaults'] as Map)),
      stepOverrides: (json['stepOverrides'] as Map).map((key, value) =>
          MapEntry(
              key as String,
              AxWorkflowSelection.fromJson(
                  Map<String, dynamic>.from(value as Map)))),
    );
  }
  AxWorkflowSelection selectionFor(String stepId) =>
      defaults.overlay(stepOverrides[stepId] ?? const AxWorkflowSelection());
  Map<String, dynamic> toJson() => {
        'schemaVersion': 1,
        'workflowId': workflowId,
        'enabled': enabled,
        'defaults': defaults.toJson(),
        'stepOverrides': {
          for (final entry in stepOverrides.entries)
            if (entry.value.toJson().isNotEmpty)
              entry.key: entry.value.toJson(),
        },
      };
}

abstract interface class AxWorkflowConfigurationDataSource {
  Future<List<AxUserWorkflowConfiguration>> loadWorkflowConfigurations();
  Future<AxUserWorkflowConfiguration> saveWorkflowConfiguration(
      AxUserWorkflowConfiguration configuration);
  Future<AxUserWorkflowConfiguration> resetWorkflowConfiguration(
      String workflowId);
}

abstract interface class AxSpaceWorkflowConfigurationDataSource {
  Future<List<AxUserWorkflowConfiguration>> loadSpaceWorkflowConfigurations(
      String spaceId);
  Future<AxUserWorkflowConfiguration> saveSpaceWorkflowConfiguration(
      String spaceId, AxUserWorkflowConfiguration configuration);
  Future<AxUserWorkflowConfiguration> resetSpaceWorkflowConfiguration(
      String spaceId, String workflowId);
}

class AxWorkflowWorkspace {
  const AxWorkflowWorkspace({required this.id, required this.name});
  final String id;
  final String name;
  factory AxWorkflowWorkspace.fromJson(Map<String, dynamic> json) =>
      AxWorkflowWorkspace(
          id: json['id'] as String, name: json['name'] as String);
}

class AxWorkflowWorkspaceSettings {
  const AxWorkflowWorkspaceSettings(
      {this.workspaceId, this.inherited = false, this.workspaces = const []});
  final String? workspaceId;
  final bool inherited;
  final List<AxWorkflowWorkspace> workspaces;
  factory AxWorkflowWorkspaceSettings.fromJson(Map<String, dynamic> json) =>
      AxWorkflowWorkspaceSettings(
          workspaceId: json['workspaceId'] as String?,
          inherited: json['inherited'] == true,
          workspaces: (json['workspaces'] as List)
              .map((v) => AxWorkflowWorkspace.fromJson(
                  Map<String, dynamic>.from(v as Map)))
              .toList());
}

abstract interface class AxWorkflowWorkspaceDataSource {
  Future<AxWorkflowWorkspaceSettings> loadWorkflowWorkspace({String? spaceId});
  Future<AxWorkflowWorkspaceSettings> selectWorkflowWorkspace(
      {String? spaceId, String? workspaceId, bool inherit = false});
}
