import 'dart:async';
import '../ax_data.dart';
import 'ax_work_history.dart';

class _RecoveryRead {
  final completer = Completer<void>();
  bool again = false;
  bool discover = false;
  bool recent = false;
}

class _StreamLease {
  _StreamLease(this.subscription);
  final StreamSubscription<Map<String, dynamic>> subscription;
  int references = 1;
}

/// One event router per session cache. Stream leases prevent shell/page duplicate
/// delivery; visible scopes own the disconnected fallback, not individual widgets.
class AxWorkRealtimeSync {
  AxWorkRealtimeSync(this.cache,
      {this.fallbackInterval = const Duration(seconds: 15)});
  final AxWorkHistoryCache cache;
  final Duration fallbackInterval;
  static final _instances = Expando<AxWorkRealtimeSync>();
  static AxWorkRealtimeSync forCache(AxWorkHistoryCache cache) =>
      _instances[cache] ??= AxWorkRealtimeSync(cache);
  final _streams = <Stream<Map<String, dynamic>>, _StreamLease>{};
  final _scopes = <String, int>{};
  final _sequences = <String, int>{};
  final _eventIds = <String>{};
  Timer? _fallback;
  bool _healthy = false;
  bool _transportHealthy = false;
  bool _needsRecovery = false;
  bool _gapStale = false;
  bool _disposed = false;
  int _generation = 0;
  _RecoveryRead? _recovery;
  int _sessionEpoch = 0;
  bool get healthy => _healthy;
  bool get polling => _fallback?.isActive == true;

  void Function() listen(Stream<Map<String, dynamic>>? events,
      {String? workstreamId}) {
    if (_disposed) return () {};
    if (events != null) {
      final existing = _streams[events];
      if (existing != null) {
        existing.references++;
      } else {
        _streams[events] = _StreamLease(events.listen((event) {
          unawaited(handle(event).catchError((Object _) {}));
        },
            onError: (Object _, StackTrace __) => _disconnected(),
            onDone: _disconnected));
      }
    }
    if (workstreamId != null) {
      _scopes[workstreamId] = (_scopes[workstreamId] ?? 0) + 1;
    }
    _scheduleFallback();
    if (workstreamId != null && _healthy) {
      unawaited(_resync(discover: false).catchError((Object _) {}));
    }
    var cancelled = false;
    return () {
      if (cancelled) return;
      cancelled = true;
      if (workstreamId != null) {
        final count = (_scopes[workstreamId] ?? 1) - 1;
        if (count <= 0) {
          _scopes.remove(workstreamId);
        } else {
          _scopes[workstreamId] = count;
        }
      }
      if (events != null) {
        final lease = _streams[events];
        if (lease != null && --lease.references <= 0) {
          _streams.remove(events);
          unawaited(lease.subscription.cancel());
        }
      }
      _scheduleFallback();
    };
  }

  void _scheduleFallback() {
    if (_disposed || _healthy || _scopes.isEmpty || cache.source == null) {
      _fallback?.cancel();
      _fallback = null;
      return;
    }
    _fallback ??= Timer.periodic(fallbackInterval, (_) {
      if (_recovery == null) {
        _needsRecovery = true;
        unawaited(_resync(discover: true).catchError((Object _) {}));
      }
    });
  }

  void _disconnected() {
    if (_disposed) return;
    _transportHealthy = false;
    _healthy = false;
    _needsRecovery = true;
    _gapStale = true;
    ++_generation;
    _scheduleFallback();
  }

  Future<void> _resync({required bool discover, bool recent = false}) {
    final pending = _recovery;
    if (pending != null) {
      if (discover) {
        pending.again = true;
        pending.discover = true;
        pending.recent |= recent;
      }
      return pending.completer.future;
    }
    final read = _RecoveryRead()
      ..discover = discover
      ..recent = recent;
    _recovery = read;
    final epoch = _sessionEpoch;
    () async {
      try {
        do {
          read.again = false;
          final discover = read.discover;
          final recent = read.recent;
          read.discover = false;
          read.recent = false;
          final generation = _generation;
          for (final id in _scopes.keys.toList()) {
            if (epoch != _sessionEpoch || _disposed) break;
            final ids = {...cache.activeIds(id), ...cache.dirtyIds(id)};
            final found = discover
                ? (recent
                    ? await cache.discoverRecent(id)
                    : await cache.discoverActive(id))
                : <String>{};
            if (epoch != _sessionEpoch || _disposed) break;
            await Future.wait(ids
                .difference(found)
                .map((requestId) => cache.refreshRequest(id, requestId)));
          }
          if (epoch == _sessionEpoch &&
              generation == _generation &&
              _transportHealthy &&
              !read.again) {
            _healthy = true;
            _gapStale = false;
            _needsRecovery = false;
            _scheduleFallback();
          }
        } while (read.again && epoch == _sessionEpoch && !_disposed);
        read.completer.complete();
      } catch (error, stack) {
        if (epoch == _sessionEpoch) {
          _healthy = _transportHealthy && !_gapStale;
          _scheduleFallback();
        }
        read.completer.completeError(error, stack);
      } finally {
        if (identical(_recovery, read)) _recovery = null;
      }
    }();
    return read.completer.future;
  }

  Future<void> handle(Map<String, dynamic> event) async {
    if (_disposed) return;
    final type = event['type'];
    if (type == 'realtime.connection') {
      if (event['status'] != 'connected') {
        _disconnected();
        return;
      }
      _transportHealthy = true;
      _healthy = !_gapStale;
      ++_generation;
      _scheduleFallback();
      await _resync(discover: _needsRecovery, recent: _needsRecovery);
      return;
    }
    if (type == 'realtime.ready') {
      _transportHealthy = true;
      _healthy = !_gapStale;
      _scheduleFallback();
      await _resync(discover: _needsRecovery, recent: _needsRecovery);
      return;
    }
    if (type == 'reconnect.required') {
      _healthy = false;
      _needsRecovery = true;
      _gapStale = true;
      ++_generation;
      _scheduleFallback();
      await _resync(discover: true, recent: true);
      return;
    }
    if (type == 'realtime.stale') {
      _disconnected();
      return;
    }
    if (!const {
      'work_request.created',
      'work_request.started',
      'work_request.completed',
      'work_request.failed',
      'work_request.cancelled',
      'step.queued',
      'step.running',
      'step.completed',
      'step.failed',
      'step.cancelled'
    }.contains(type)) {
      return;
    }
    final raw = event['payload'];
    if (raw is! Map) return;
    final payload = Map<String, dynamic>.from(raw);
    final id = payload['workRequestId'];
    final workstreamId = payload['workstreamId'];
    if (id is! String ||
        id.isEmpty ||
        workstreamId is! String ||
        workstreamId.isEmpty) {
      return;
    }
    final sequence = event['sequence'];
    final sequenceKey = '${event['workspaceId']}:$workstreamId:$id';
    if (sequence is int && sequence > 0) {
      if (sequence <= (_sequences[sequenceKey] ?? -1)) return;
      _sequences[sequenceKey] = sequence;
    }
    final eventId = event['eventId'];
    if (eventId is String) {
      if (!_eventIds.add(eventId)) return;
      if (_eventIds.length > 1000) _eventIds.remove(_eventIds.first);
    }
    final full = payload['workRequest'];
    if (full is Map &&
        full['id'] == id &&
        full['createdAt'] is String &&
        full['workflowId'] is String &&
        full['workflowVersion'] is int &&
        full['prompt'] is String &&
        full['requestedByName'] is String &&
        full['status'] is String &&
        (full['workstreamId'] == null ||
            full['workstreamId'] == workstreamId) &&
        full['steps'] is List &&
        (full['steps'] as List).every((v) => v is Map) &&
        (full['status'] != 'completed' || full.containsKey('finalText'))) {
      try {
        cache.patchRequest(workstreamId,
            AxWorkRequest.fromJson(Map<String, dynamic>.from(full)));
        return;
      } catch (_) {
        // Incomplete optional metadata falls back to the authoritative detail.
      }
    }
    final current = cache.request(workstreamId, id);
    final status = payload['status'];
    if (current != null &&
        status is String &&
        const {'queued', 'running', 'waiting'}.contains(current.status)) {
      if ((type == 'work_request.started' && status == 'running') ||
          (type == 'work_request.created' && status == 'queued')) {
        cache.patchRequest(workstreamId, current.copyWith(status: status));
        return;
      }
      final kind = payload['stepKind'];
      if ((type == 'step.queued' && status == 'queued' ||
              type == 'step.running' && status == 'running') &&
          kind is String &&
          current.steps.any((s) =>
              s.kind == kind &&
              const {'queued', 'running', 'waiting'}.contains(s.status))) {
        cache.patchRequest(
            workstreamId,
            current.copyWith(steps: [
              for (final step in current.steps)
                step.kind == kind ? step.withStatus(status) : step
            ]));
        return;
      }
    }
    // Terminal and incomplete events need result/error/Step details.
    try {
      await cache.refreshRequest(workstreamId, id, supersede: true);
    } catch (_) {
      _needsRecovery = true;
      _scheduleFallback();
      rethrow;
    }
  }

  void reset() {
    ++_generation;
    ++_sessionEpoch;
    _recovery = null;
    _sequences.clear();
    _eventIds.clear();
    _healthy = false;
    _transportHealthy = false;
    _needsRecovery = false;
    _gapStale = false;
    _fallback?.cancel();
    _fallback = null;
  }

  void dispose() {
    _disposed = true;
    reset();
    for (final lease in _streams.values) {
      unawaited(lease.subscription.cancel());
    }
    _streams.clear();
    _scopes.clear();
  }
}
