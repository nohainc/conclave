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

  late final defaultQuery = AxQuery<String>(
      key: AxQueryKey(['workflow-default', spaceId ?? 'user']),
      staleTime: const Duration(minutes: 45),
      load: () async {
        final api = source is AxWorkflowDefaultDataSource
            ? source as AxWorkflowDefaultDataSource
            : null;
        if (api == null) return 'chat';
        return spaceId == null
            ? api.loadWorkflowDefault()
            : api.loadSpaceWorkflowDefault(spaceId!);
      });

  Future<List<AxUserWorkflowConfiguration>> ensure() =>
      engine.ensure(query, policy: AxCachePolicy.cacheFirst);
  Future<List<AxUserWorkflowConfiguration>> refresh() => engine.refresh(query);
  Future<String> ensureDefault() =>
      engine.ensure(defaultQuery, policy: AxCachePolicy.cacheFirst);
  Future<String> refreshDefault() => engine.refresh(defaultQuery);

  Future<void> setDefault(String workflowId) async {
    if (_writeLease != null) {
      throw StateError('A workflow update is already pending');
    }
    final api = source is AxWorkflowDefaultDataSource
        ? source as AxWorkflowDefaultDataSource
        : null;
    if (api == null) throw StateError('Workflow default is unavailable');
    final epoch = _sessionEpoch;
    final lease = Object();
    _writeLease = lease;
    try {
      await engine.mutate(AxMutation<String>(
          query: defaultQuery,
          execute: () => spaceId == null
              ? api.saveWorkflowDefault(workflowId)
              : api.saveSpaceWorkflowDefault(spaceId!, workflowId)));
      if (epoch != _sessionEpoch) throw const AxMutationSuperseded();
      if (spaceId == null) {
        engine.invalidate(AxQueryKey(['workflow-default']), prefix: true);
        await engine
            .refreshStaleWhere(
                (key) => key.startsWith(AxQueryKey(['workflow-default'])))
            .then<void>((_) {}, onError: (Object _, StackTrace __) {});
      }
    } finally {
      if (identical(_writeLease, lease)) _writeLease = null;
    }
  }

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
      // Workspace changes reset the scoped workflow preferences on Cloud. Drop
      // the old values before reloading so a successful reset cannot leave a
      // stale Space default or disabled configuration visible while the new
      // effective settings are fetched.
      engine.remove(queryKey);
      engine.remove(defaultQuery.key);
      // Refresh both resources independently. A transient configuration read
      // failure must not prevent the default workflow from being updated.
      await Future.wait<Object?>([refresh(), refreshDefault()]);
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
    engine.remove(defaultQuery.key);
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
        engine.invalidate(AxQueryKey(['workflow-default']), prefix: true);
        await engine
            .refreshStaleWhere((key) =>
                key.startsWith(AxQueryKey(['space-workflow-configurations'])) ||
                key.startsWith(AxQueryKey(['workflow-default'])))
            .then<void>((_) {}, onError: (Object _, StackTrace __) {});
      }
      if (source is AxWorkflowDefaultDataSource) {
        engine.invalidate(defaultQuery.key);
        await refreshDefault();
      }
    } finally {
      if (identical(_writeLease, lease)) {
        _writeLease = null;
      }
    }
  }
}
