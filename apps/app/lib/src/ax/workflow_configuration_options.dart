import 'ax_models.dart';
import 'ax_workflow_configuration.dart';

/// Capability projection for configuration, independent of execution readiness.
class AxWorkflowSelectionOptions {
  AxWorkflowSelectionOptions(this.workers);
  final List<AxWorker> workers;

  AxWorker? worker(String? id) {
    for (final value in workers) {
      if (value.id == id) return value;
    }
    return null;
  }

  Iterable<AxWorker> _candidates(String? id) =>
      workers.where((value) => id == null || value.id == id);

  bool _supportsModel(AxWorkerExecutionOptions options, String? model) =>
      model == null ||
      (options.modelSelectionSupported &&
          (options.allowsCustomModel ||
              options.allowedModelIds.contains(model)));

  Map<String, String> models(String? workerId) {
    final result = <String, String>{};
    for (final candidate in _candidates(workerId)) {
      final options = candidate.executionOptions;
      if (options == null || !options.modelSelectionSupported) continue;
      for (final model in options.models) {
        if (_supportsModel(options, model.id)) result[model.id] = model.name;
      }
      for (final id in options.allowedModelIds) {
        result.putIfAbsent(id, () => id);
      }
    }
    return result;
  }

  List<String> efforts(AxWorkflowSelection effective) {
    final result = <String>{};
    for (final candidate in _candidates(effective.worker)) {
      final options = candidate.executionOptions;
      if (options == null || !_supportsModel(options, effective.model)) {
        continue;
      }
      final effort = options.effortsForModel(effective.model);
      if (effort.supported) result.addAll(effort.values);
    }
    return List.unmodifiable(result);
  }

  String? _validateProfile(
      AxWorkerExecutionOptions options, AxWorkflowSelection value) {
    if (!_supportsModel(options, value.model)) {
      return 'The selected model is not supported by this Worker.';
    }
    final effort = options.effortsForModel(value.model);
    if (value.effort != null &&
        (!effort.supported || !effort.values.contains(value.effort))) {
      return 'The selected effort is not supported for this Worker and model.';
    }
    return null;
  }

  /// Match Cloud's unchanged-unavailable intent rule without treating offline
  /// readiness as a capability failure. Cloud remains the write authority.
  String? validate(AxWorkflowSelection value,
      {required AxWorkflowSelection saved}) {
    final same = value.worker == saved.worker &&
        value.model == saved.model &&
        value.effort == saved.effort;
    if (value.worker == null) {
      if (value.model == null && value.effort == null) return null;
      if (workers.any((candidate) =>
          candidate.executionOptions != null &&
          _validateProfile(candidate.executionOptions!, value) == null)) {
        return null;
      }
      return 'No Worker Profile supports this model and effort combination.';
    }
    final selected = worker(value.worker);
    if ((selected == null || selected.executionOptions == null) && same) {
      return null;
    }
    if (selected == null) {
      return 'This Worker is unavailable. Restore the saved selection or choose another Worker.';
    }
    if (value.model == null && value.effort == null) return null;
    if (selected.executionOptions == null) {
      return 'Model and effort capabilities are unavailable for this Worker.';
    }
    return _validateProfile(selected.executionOptions!, value);
  }
}
