import '../ax_models.dart';
import 'ax_sync_engine.dart';

/// Routes shared transport events without reading navigation state.
/// Work Request and Step events use AxWorkRealtimeSync's single-entity router.
class AxRealtimeCacheRouter {
  AxRealtimeCacheRouter(this.engine,
      {this.discussionChanged,
      this.discussionResynchronize,
      this.discussionObserved,
      this.projectRemoved});
  final Future<void> Function(
      String workstreamId, String type, String entityId)? discussionChanged;
  final Future<void> Function(String workstreamId)? discussionResynchronize;
  final bool Function(String workstreamId)? discussionObserved;
  final void Function(String projectId)? projectRemoved;
  final AxSyncEngine engine;
  final _eventIds = <String>{};
  final _recoveries = <(String, String?), Future<void>>{};

  void reset() {
    _eventIds.clear();
    _recoveries.clear();
  }

  Future<void> handle(Map<String, dynamic> event) async {
    final type = event['type'];
    if (type is! String) return;
    final eventId = event['eventId'];
    if (eventId is String) {
      if (!_eventIds.add(eventId)) return;
      if (_eventIds.length > 1000) _eventIds.remove(_eventIds.first);
    }
    final payload =
        event['payload'] is Map ? event['payload'] as Map : const {};
    String? id(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    final projectId = id(event['projectId']) ?? id(payload['projectId']);
    final workstreamId =
        id(event['workstreamId']) ?? id(payload['workstreamId']);
    if (type == 'reconnect.required' || type == 'realtime.ready') {
      final scope = AxSyncScope.fromEvent(event);
      final key = (scope.kind, scope.id);
      final pending = _recoveries[key];
      if (pending != null) return pending;
      late final Future<void> recovery;
      recovery = _recover(scope).whenComplete(() {
        if (identical(_recoveries[key], recovery)) _recoveries.remove(key);
      });
      _recoveries[key] = recovery;
      return recovery;
    }
    if (type.startsWith('worker.inventory.')) {
      await engine.revalidateWhere((key) => key == AxQueryKey(['workers']));
      return;
    }
    if (type.startsWith('discussion.') &&
        workstreamId != null &&
        discussionChanged != null) {
      final entityId = id(payload['entityId']);
      if (entityId != null) {
        await discussionChanged!(workstreamId, type, entityId);
      }
      return;
    }
    if (type == 'project_workspace_grant.updated') {
      if (projectId != null) {
        await engine.revalidateWhere((key) =>
            key == AxQueryKey(['project', projectId, 'workspace-grants']));
      }
      return;
    }
    if (type.startsWith('project.') || type.startsWith('invitation.')) {
      final affected = projectId ?? id(payload['entityId']);
      if (affected == null) return;
      if (type == 'project.deleted') {
        projectRemoved?.call(affected);
        engine.remove(AxQueryKey(['project', affected]), prefix: true);
        await engine.revalidateWhere((key) => key == AxQueryKey(['projects']));
        return;
      }
      await engine.revalidateWhere((key) =>
          (key.parts[0] == 'project' &&
              key.parts.length >= 2 &&
              key.parts[1] == affected) ||
          key == AxQueryKey(['projects']) ||
          key == AxQueryKey(['me', 'invitations']));
    } else if (type.startsWith('workstream.')) {
      final affectedWorkstream = workstreamId ?? id(payload['entityId']);
      final parents = <String>{if (projectId != null) projectId};
      if (affectedWorkstream != null) {
        for (final collection
            in engine.cachedValues<List<AxWorkstream>>().entries) {
          final parts = collection.key.parts;
          if (parts.length == 3 &&
              parts[0] == 'project' &&
              parts[2] == 'workstreams' &&
              collection.value.any((item) => item.id == affectedWorkstream)) {
            parents.add(parts[1]);
          }
        }
      }
      await engine.revalidateWhere((key) =>
          (!type.contains('discussion') &&
              key.parts.length == 3 &&
              key.parts[0] == 'project' &&
              parents.contains(key.parts[1]) &&
              key.parts[2] == 'workstreams') ||
          (workstreamId != null &&
              key == AxQueryKey(['workstream', workstreamId, 'discussion']) &&
              type.contains('discussion')));
    } else if (type.startsWith('discussion.') && workstreamId != null) {
      await engine.revalidateWhere((key) =>
          key == AxQueryKey(['workstream', workstreamId, 'discussion']));
    }
  }

  Future<void> _recover(AxSyncScope scope) async {
    engine.invalidateScope(scope);
    final discussions = engine.relevantKeys
        .where((key) =>
            scope.matches(key) &&
            key.parts.length == 3 &&
            key.parts[0] == 'workstream' &&
            key.parts[2] == 'discussion' &&
            (scope.kind != 'user' || _observed(key)))
        .toList();
    await Future.wait([
      engine.refreshStaleWhere((key) =>
          scope.matches(key) &&
          _managed(key) &&
          (scope.kind != 'user' || _observed(key)) &&
          (discussionResynchronize == null || key.parts[0] != 'workstream')),
      if (discussionResynchronize != null)
        for (final key in discussions) discussionResynchronize!(key.parts[1]),
    ]);
  }

  bool _observed(AxQueryKey key) => key.parts.length == 3 &&
          key.parts[0] == 'workstream' &&
          key.parts[2] == 'discussion' &&
          discussionObserved != null
      ? discussionObserved!(key.parts[1])
      : engine.isObserved(key);

  bool _managed(AxQueryKey key) =>
      key == AxQueryKey(['workers']) ||
      (key.parts[0] == 'project' && key.parts.length >= 2) ||
      (key.parts.length == 3 &&
          key.parts[0] == 'workstream' &&
          key.parts[2] == 'discussion');
}
