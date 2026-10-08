import '../ax_data.dart';
import 'ax_sync_engine.dart';

/// Session-owned preferences. Navigation never forces a preference refresh.
class AxWorkflowConfigurations {
  AxWorkflowConfigurations(this.source, {required this.engine});
  final AxDataSource source;
  final AxSyncEngine engine;
  static final key = AxQueryKey(['user-workflow-configurations']);
  AxWorkflowConfigurationDataSource get _api {
    if (source is AxWorkflowConfigurationDataSource) {
      return source as AxWorkflowConfigurationDataSource;
    }
    throw StateError('Workflow configuration is unavailable');
  }

  late final query = AxQuery<List<AxUserWorkflowConfiguration>>(
      key: key,
      staleTime: const Duration(minutes: 45),
      load: () async =>
          List.unmodifiable(await _api.loadWorkflowConfigurations()));

  Future<List<AxUserWorkflowConfiguration>> ensure() =>
      engine.ensure(query, policy: AxCachePolicy.cacheFirst);
  Future<List<AxUserWorkflowConfiguration>> refresh() => engine.refresh(query);

  int _sessionEpoch = 0;
  Object? _writeLease;
  void clear() {
    _sessionEpoch++;
    _writeLease = null;
    engine.remove(key);
  }

  Future<void> save(AxUserWorkflowConfiguration value) =>
      _write(value.workflowId, () => _api.saveWorkflowConfiguration(value));
  Future<void> reset(String workflowId) =>
      _write(workflowId, () => _api.resetWorkflowConfiguration(workflowId));

  Future<void> _write(String workflowId,
      Future<AxUserWorkflowConfiguration> Function() execute) async {
    if (_writeLease != null) {
      throw StateError('A workflow update is already pending');
    }
    final epoch = _sessionEpoch;
    final lease = Object();
    _writeLease = lease;
    try {
      await ensure();
      if (epoch != _sessionEpoch) {
        throw const AxMutationSuperseded();
      }
      await engine.mutate(AxMutation<List<AxUserWorkflowConfiguration>>(
          query: query,
          execute: () async {
            final result = await execute();
            return List.unmodifiable([
              ...?engine
                  .peek(query)
                  .data
                  ?.where((item) => item.workflowId != workflowId),
              result,
            ]);
          }));
    } finally {
      if (identical(_writeLease, lease)) {
        _writeLease = null;
      }
    }
  }
}
