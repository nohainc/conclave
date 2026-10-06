// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;

import 'package:conclave_protocol/conclave_protocol.dart';

import 'realtime_client_stub.dart';
import 'realtime_health.dart';
import 'realtime_cursors.dart';

class _BrowserRealtimeClient implements RealtimeClient {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  html.WebSocket? _socket;
  Uri? _endpoint;
  String? _projectId;
  String? _workstreamId;
  String? _runId;
  String? _executionWorkspaceId;
  Timer? _reconnectTimer;
  late final _health = RealtimeHealthMonitor(
      ping: () => _send({'type': 'ping'}),
      onStale: () {
        if (_closed) return;
        _events.add({'type': 'realtime.connection', 'status': 'stale'});
        _socket?.close();
        _scheduleReconnect();
      });
  int _attempt = 0;
  final _cursors = RealtimeCursors();
  bool _closed = false;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<void> connect(Uri endpoint, [String? workspaceId]) async {
    _closed = false;
    _endpoint = endpoint;
    _attempt = 0;
    _open();
  }

  @override
  Future<void> setWorkspace(String workspaceId) async {
    await setScopes(executionWorkspaceId: workspaceId);
  }

  @override
  Future<void> setScopes({
    String? projectId,
    String? workstreamId,
    String? runId,
    String? executionWorkspaceId,
  }) async {
    final previous = _currentScopes();
    if (_socket?.readyState == html.WebSocket.OPEN) {
      for (final scope in previous) {
        _send({'type': 'unsubscribe', 'scope': scope});
      }
    }
    _projectId = projectId;
    _workstreamId = workstreamId;
    _runId = runId;
    _executionWorkspaceId = executionWorkspaceId;
    if (_socket?.readyState == html.WebSocket.OPEN) {
      _subscribeCurrentScopes();
    }
  }

  void _open() {
    final endpoint = _endpoint;
    if (_closed || endpoint == null) return;
    final socket = html.WebSocket(endpoint.toString());
    _socket = socket;
    socket.onOpen.listen((_) {
      if (_closed || !identical(_socket, socket)) return;
      _attempt = 0;
      _events.add({'type': 'realtime.connection', 'status': 'connected'});
      _send(_cursors.hello());
      _send({
        'type': 'subscribe',
        'scope': {'kind': 'user'}
      });
      _subscribeCurrentScopes();
      _health.start();
    });
    socket.onMessage.listen((event) {
      if (_closed || !identical(_socket, socket)) return;
      final data = event.data;
      if (data is! String) return;
      try {
        final decoded = jsonDecode(data);
        if (decoded is! Map) return;
        final message = Map<String, dynamic>.from(decoded);
        if (message['type'] == 'realtime.pong') {
          _health.acknowledge();
        } else if (message['type'] == 'realtime.ready') {
          _events.add(message);
        } else if (message['type'] == 'event' && message['event'] is Map) {
          final eventValue = Map<String, dynamic>.from(message['event'] as Map);
          final type = eventValue['type'];
          if (type is String && durableRealtimeEventTypes.contains(type)) {
            _cursors.record(eventValue);
          }
          _events.add(eventValue);
        } else if (message['type'] == 'reconnect.required') {
          _cursors.record(message);
          // Query routers reconcile the affected stream through authenticated HTTP.
          _events.add(message);
        }
      } on FormatException {
        // Ignore malformed server frames; reconnect handling remains intact.
      }
    });
    socket.onClose.listen((_) {
      if (identical(_socket, socket)) _scheduleReconnect();
    });
    socket.onError.listen((_) {
      if (identical(_socket, socket)) _scheduleReconnect();
    });
  }

  void _subscribeCurrentScopes() {
    for (final scope in _currentScopes()) {
      _send({'type': 'subscribe', 'scope': scope});
    }
  }

  List<Map<String, dynamic>> _currentScopes() => [
        if (_projectId != null) {'kind': 'project', 'projectId': _projectId},
        if (_workstreamId != null)
          {'kind': 'workstream', 'workstreamId': _workstreamId},
        if (_runId != null) {'kind': 'run', 'runId': _runId},
        if (_executionWorkspaceId != null)
          {
            'kind': 'execution_workspace',
            'executionWorkspaceId': _executionWorkspaceId
          },
      ];

  void _scheduleReconnect() {
    if (_closed || _reconnectTimer?.isActive == true) return;
    _health.stop();
    _events.add({'type': 'realtime.connection', 'status': 'reconnecting'});
    final cappedAttempt = math.min(_attempt++, 8);
    final jitter = 0.75 + math.Random().nextDouble() * 0.5;
    final delay = Duration(
        milliseconds: (500 * math.pow(2, cappedAttempt) * jitter).round());
    _reconnectTimer = Timer(delay, _open);
  }

  void _send(Map<String, dynamic> message) {
    final socket = _socket;
    if (socket?.readyState == html.WebSocket.OPEN) {
      socket!.send(jsonEncode(message));
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _health.stop();
    _reconnectTimer?.cancel();
    _socket?.close();
    await _events.close();
  }
}

RealtimeClient createRealtimeClient() => _BrowserRealtimeClient();
