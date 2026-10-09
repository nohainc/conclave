import '../ax_models.dart';
import 'ax_sync_engine.dart';

/// Routes shared transport events without reading navigation state.
/// Work Request and Step events use AxWorkRealtimeSync's single-entity router.
class AxRealtimeCacheRouter {
  AxRealtimeCacheRouter(this.engine,
      {this.discussionChanged,
      this.discussionResynchronize,
      this.discussionObserved});
  final Future<void> Function(String threadId, String type, String entityId)?
      discussionChanged;
  final Future<void> Function(String threadId)? discussionResynchronize;
  final bool Function(String threadId)? discussionObserved;
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
    final spaceId = id(event['spaceId']) ??
        id(payload['spaceId']) ??
        id(event['spaceId']) ??
        id(payload['spaceId']);
    final threadId = id(event['threadId']) ??
        id(payload['threadId']) ??
        id(event['threadId']) ??
        id(payload['threadId']);
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
    if (type == 'people.updated' || type.startsWith('space.')) {
      try {
        await engine.revalidateWhere((key) => key == AxQueryKey(['people']));
      } catch (_) {
        // People exposes its own read error; continue updating Space state.
      }
      if (type == 'people.updated') return;
    }
    if (type.startsWith('worker.inventory.')) {
      await engine.revalidateWhere((key) => key == AxQueryKey(['workers']));
      return;
    }
    if (type.startsWith('discussion.') &&
        threadId != null &&
        discussionChanged != null) {
      final entityId = id(payload['entityId']);
      if (entityId != null) {
        await discussionChanged!(threadId, type, entityId);
      }
      return;
    }
    if (type.startsWith('space.') ||
        type.startsWith('space.') ||
        type.startsWith('invitation.')) {
      final affected = spaceId ?? id(payload['entityId']);
      if (affected == null) return;
      if (type == 'space.deleted') {
        engine.remove(AxQueryKey(['space', affected]), prefix: true);
        engine.remove(AxQueryKey(['space-workflow-configurations', affected]));
        engine.remove(AxQueryKey(['workflow-workspace', affected]));
        await engine.revalidateWhere((key) => key == AxQueryKey(['spaces']));
        return;
      }
      await engine.revalidateWhere((key) =>
          (key.parts[0] == 'space' &&
              key.parts.length >= 2 &&
              key.parts[1] == affected) ||
          key == AxQueryKey(['space-workflow-configurations', affected]) ||
          key == AxQueryKey(['workflow-workspace', affected]) ||
          key == AxQueryKey(['spaces']) ||
          key == AxQueryKey(['me', 'invitations']));
    } else if (type.startsWith('thread.') || type.startsWith('thread.')) {
      final affectedThread = threadId ?? id(payload['entityId']);
      final parents = <String>{if (spaceId != null) spaceId};
      if (affectedThread != null) {
        for (final collection
            in engine.cachedValues<List<AxThread>>().entries) {
          final parts = collection.key.parts;
          if (parts.length == 3 &&
              parts[0] == 'space' &&
              parts[2] == 'threads' &&
              collection.value.any((item) => item.id == affectedThread)) {
            parents.add(parts[1]);
          }
        }
      }
      await engine.revalidateWhere((key) =>
          (!type.contains('discussion') &&
              key.parts.length == 3 &&
              key.parts[0] == 'space' &&
              parents.contains(key.parts[1]) &&
              key.parts[2] == 'threads') ||
          (threadId != null &&
              key == AxQueryKey(['thread', threadId, 'discussion']) &&
              type.contains('discussion')));
    } else if (type.startsWith('discussion.') && threadId != null) {
      await engine.revalidateWhere(
          (key) => key == AxQueryKey(['thread', threadId, 'discussion']));
    }
  }

  Future<void> _recover(AxSyncScope scope) async {
    engine.invalidateScope(scope);
    final discussions = engine.relevantKeys
        .where((key) =>
            scope.matches(key) &&
            key.parts.length == 3 &&
            key.parts[0] == 'thread' &&
            key.parts[2] == 'discussion' &&
            (scope.kind != 'user' || _observed(key)))
        .toList();
    await Future.wait([
      engine.refreshStaleWhere((key) =>
          scope.matches(key) &&
          _managed(key) &&
          (scope.kind != 'user' ||
              key == AxQueryKey(['people']) ||
              _observed(key)) &&
          (discussionResynchronize == null || key.parts[0] != 'thread')),
      if (discussionResynchronize != null)
        for (final key in discussions) discussionResynchronize!(key.parts[1]),
    ]);
  }

  bool _observed(AxQueryKey key) => key.parts.length == 3 &&
          key.parts[0] == 'thread' &&
          key.parts[2] == 'discussion' &&
          discussionObserved != null
      ? discussionObserved!(key.parts[1])
      : engine.isObserved(key);

  bool _managed(AxQueryKey key) =>
      key == AxQueryKey(['workers']) ||
      key == AxQueryKey(['people']) ||
      (key.parts[0] == 'space' && key.parts.length >= 2) ||
      key.parts[0] == 'space-workflow-configurations' ||
      key.parts[0] == 'workflow-workspace' ||
      (key.parts.length == 3 &&
          key.parts[0] == 'thread' &&
          key.parts[2] == 'discussion');
}
