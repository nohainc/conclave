import '../ax_data.dart';
import 'ax_sync_engine.dart';

typedef AxWorkspaceGrants = List<Map<String, dynamic>>;
typedef _GrantChange = AxWorkspaceGrants Function(AxWorkspaceGrants);

/// Shared Space collection with independent optimistic grant overlays.
class AxSpaceWorkspaceGrants {
  AxSpaceWorkspaceGrants(this.source, {AxSyncEngine? engine})
      : engine = engine ?? AxSyncEngine();
  final AxDataSource? source;
  final AxSyncEngine engine;
  static final _sources = Expando<AxSpaceWorkspaceGrants>();
  static AxSpaceWorkspaceGrants forSource(AxDataSource? source) =>
      source == null
          ? AxSpaceWorkspaceGrants(null)
          : _sources[source] ??= AxSpaceWorkspaceGrants(source);
  final _pending = <String, Map<int, _GrantChange>>{};
  final _listeners = <String, Set<void Function()>>{};
  int _nextId = 0;
  int _epoch = 0;
  final _spaceEpochs = <String, int>{};

  AxQueryKey key(String id) => AxQueryKey(['space', id, 'workspace-grants']);
  AxQuery<AxWorkspaceGrants> query(String id) => AxQuery(
      key: key(id),
      staleTime: const Duration(minutes: 1),
      load: () async =>
          _freeze(await source?.loadSpaceWorkspaces(spaceId: id) ?? const []));

  static dynamic _freezeValue(dynamic value) => value is Map
      ? Map<String, dynamic>.unmodifiable(
          value.map((k, v) => MapEntry(k as String, _freezeValue(v))))
      : value is List
          ? List.unmodifiable(value.map(_freezeValue))
          : value;
  static AxWorkspaceGrants _freeze(Iterable<Map<String, dynamic>> values) =>
      List.unmodifiable(
          values.map((value) => _freezeValue(value) as Map<String, dynamic>));

  AxQueryState<AxWorkspaceGrants> peek(String id) {
    final state = engine.peek(query(id));
    var values = state.data ?? const <Map<String, dynamic>>[];
    for (final change in _pending[id]?.values ?? const <_GrantChange>[]) {
      values = _freeze(change(values));
    }
    return AxQueryState(
        data: values,
        hasData: state.hasData || (_pending[id]?.isNotEmpty ?? false),
        isFetching: state.isFetching,
        isStale: state.isStale,
        error: state.error,
        lastFetchedAt: state.lastFetchedAt,
        lastAccessedAt: state.lastAccessedAt,
        generation: state.generation);
  }

  Future<AxWorkspaceGrants> ensure(String id) => engine.ensure(query(id));
  Future<AxWorkspaceGrants> refresh(String id) => engine.refresh(query(id));

  void Function() watch(
      String id, void Function(AxQueryState<AxWorkspaceGrants>) listener) {
    void notify() => listener(peek(id));
    (_listeners[id] ??= {}).add(notify);
    final cancel =
        engine.watch(query(id), (_) => notify(), fireImmediately: false);
    return () {
      cancel();
      _listeners[id]?.remove(notify);
    };
  }

  void _notify(String id) {
    for (final listener in _listeners[id]?.toList() ?? <void Function()>[]) {
      listener();
    }
  }

  Future<void> _mutate(
      String id, _GrantChange change, Future<void> Function() execute) async {
    final epoch = _epoch;
    final spaceEpoch = _spaceEpochs[id] ?? 0;
    bool current() => epoch == _epoch && spaceEpoch == (_spaceEpochs[id] ?? 0);
    final token = ++_nextId;
    engine.peek(query(id));
    final fence = engine.fence(key(id));
    await engine.mutations.run(AxMutationOperation<void, int>(
      rejectSuperseded: false,
      optimisticUpdate: () {
        (_pending[id] ??= {})[token] = change;
        _notify(id);
        return token;
      },
      isCurrent: (_) => current() && fence(),
      execute: (_) => execute(),
      commit: (_, token) {
        engine.update(
            query(id), (state) => _freeze(change(state.data ?? const [])));
        _pending[id]?.remove(token);
        _notify(id);
      },
      rollback: (_, __, token) {
        _pending[id]?.remove(token);
        _notify(id);
      },
      invalidate: (_, __) async {
        engine.invalidate(key(id));
        await refresh(id);
      },
    ));
  }

  Future<void> create(
      {required String spaceId,
      required String workspaceId,
      String? workspaceName,
      List<String> allowedPermissions = const []}) {
    final permissions = List<String>.unmodifiable(allowedPermissions);
    final localId = 'local-grant:${++_nextId}';
    return _mutate(
        spaceId,
        (values) => [
              ...values.where((value) => value['workspaceId'] != workspaceId),
              {
                'id': localId,
                'spaceId': spaceId,
                'workspaceId': workspaceId,
                'workspaceName': workspaceName,
                'status': 'active',
                'allowedPermissions': permissions,
                'optimistic': true
              },
            ],
        () => source!.requestSpaceWorkspace(
            spaceId: spaceId,
            workspaceId: workspaceId,
            allowedPermissions: permissions));
  }

  Future<void> updatePermissions(
      {required String spaceId,
      required String grantId,
      required List<String> allowedPermissions}) {
    final permissions = List<String>.unmodifiable(allowedPermissions);
    return _mutate(
        spaceId,
        (values) => [
              for (final value in values)
                if ((value['id'] ?? value['grantId']) == grantId)
                  {...value, 'allowedPermissions': permissions}
                else
                  value,
            ],
        () => source!.updateWorkspaceSpacePermissions(
            grantId: grantId, allowedPermissions: permissions));
  }

  Future<void> revoke({required String spaceId, required String grantId}) =>
      _mutate(
          spaceId,
          (values) => values
              .where((value) => (value['id'] ?? value['grantId']) != grantId)
              .toList(),
          () => source!.revokeWorkspaceSpaceGrant(grantId: grantId));

  void remove(String id) {
    _spaceEpochs[id] = (_spaceEpochs[id] ?? 0) + 1;
    _pending.remove(id);
    engine.remove(key(id));
    _notify(id);
  }

  void clear() {
    ++_epoch;
    _pending.clear();
    final keys = engine.relevantKeys
        .where((key) =>
            key.parts.length == 3 &&
            key.parts[0] == 'space' &&
            key.parts[2] == 'workspace-grants')
        .toList();
    for (final key in keys) {
      engine.remove(key);
    }
    for (final id in _listeners.keys.toList()) {
      _notify(id);
    }
  }
}
