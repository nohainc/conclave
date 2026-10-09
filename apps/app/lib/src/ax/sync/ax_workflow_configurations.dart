import '../ax_data.dart';
import 'ax_sync_engine.dart';

/// Session-owned global or Space preferences. Navigation reuses the scoped query.
class AxWorkflowConfigurations {
  AxWorkflowConfigurations(this.source, {required this.engine, this.spaceId});
  final String? spaceId;
  AxQueryKey get queryKey => spaceId == null
      ? key
      : AxQueryKey(['space-workflow-configurations', spaceId!]);
  AxSpaceWorkflowConfigurationDataSource get _spaceApi =>
      source as AxSpaceWorkflowConfigurationDataSource;
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
      key: queryKey,
      staleTime: const Duration(minutes: 45),
      load: () async => List.unmodifiable(spaceId == null
          ? await _api.loadWorkflowConfigurations()
          : await _spaceApi.loadSpaceWorkflowConfigurations(spaceId!)));

  Future<List<AxUserWorkflowConfiguration>> ensure() =>
      engine.ensure(query, policy: AxCachePolicy.cacheFirst);
  Future<List<AxUserWorkflowConfiguration>> refresh() => engine.refresh(query);

  AxQueryKey get workspaceKey =>
      AxQueryKey(['workflow-workspace', spaceId ?? 'user']);
  late final workspaceQuery = AxQuery<AxWorkflowWorkspaceSettings>(
      key: workspaceKey,
      staleTime: const Duration(minutes: 45),
      load: () => (source as AxWorkflowWorkspaceDataSource)
          .loadWorkflowWorkspace(spaceId: spaceId));
  Future<AxWorkflowWorkspaceSettings> ensureWorkspace() =>
      engine.ensure(workspaceQuery, policy: AxCachePolicy.cacheFirst);
  Future<void> selectWorkspace(String? workspaceId,
      {bool inherit = false}) async {
    if (_writeLease != null) {
      throw StateError('A workflow update is already pending');
    }
    final epoch = _sessionEpoch;
    final lease = Object();
    _writeLease = lease;
    try {
      await engine.mutate(AxMutation<AxWorkflowWorkspaceSettings>(
          query: workspaceQuery,
          execute: () => (source as AxWorkflowWorkspaceDataSource)
              .selectWorkflowWorkspace(
                  spaceId: spaceId,
                  workspaceId: workspaceId,
                  inherit: inherit)));
      if (epoch != _sessionEpoch) throw const AxMutationSuperseded();
      engine.invalidate(queryKey);
      await refresh();
      if (epoch != _sessionEpoch) throw const AxMutationSuperseded();
      if (spaceId == null) {
        engine.invalidate(AxQueryKey(['space-workflow-configurations']),
            prefix: true);
        engine.invalidate(AxQueryKey(['workflow-workspace']), prefix: true);
        await engine
            .refreshStaleWhere((key) =>
                key.startsWith(AxQueryKey(['space-workflow-configurations'])) ||
                key.startsWith(AxQueryKey(['workflow-workspace'])))
            .then<void>((_) {}, onError: (Object _, StackTrace __) {});
      }
      for (final key in engine.relevantKeys.toList()) {
        if (key.parts.length == 3 &&
            key.parts[0] == 'space' &&
            key.parts[2] == 'workspace-grants' &&
            (spaceId == null || key.parts[1] == spaceId)) {
          engine.invalidate(key);
        }
      }
      await engine
          .refreshStaleWhere((key) =>
              key.parts.length == 3 &&
              key.parts[0] == 'space' &&
              key.parts[2] == 'workspace-grants' &&
              (spaceId == null || key.parts[1] == spaceId))
          .then<void>((_) {}, onError: (Object _, StackTrace __) {});
    } finally {
      if (identical(_writeLease, lease)) _writeLease = null;
    }
  }

  int _sessionEpoch = 0;
  Object? _writeLease;
  void clear() {
    _sessionEpoch++;
    _writeLease = null;
    engine.remove(queryKey);
    engine.remove(workspaceKey);
  }

  Future<void> save(AxUserWorkflowConfiguration value) => _write(
      value.workflowId,
      () => spaceId == null
          ? _api.saveWorkflowConfiguration(value)
          : _spaceApi.saveSpaceWorkflowConfiguration(spaceId!, value));
  Future<void> reset(String workflowId) => _write(
      workflowId,
      () => spaceId == null
          ? _api.resetWorkflowConfiguration(workflowId)
          : _spaceApi.resetSpaceWorkflowConfiguration(spaceId!, workflowId));

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
      if (spaceId == null) {
        engine.invalidate(AxQueryKey(['space-workflow-configurations']),
            prefix: true);
        await engine
            .refreshStaleWhere((key) =>
                key.startsWith(AxQueryKey(['space-workflow-configurations'])))
            .then<void>((_) {}, onError: (Object _, StackTrace __) {});
      }
    } finally {
      if (identical(_writeLease, lease)) {
        _writeLease = null;
      }
    }
  }
}
