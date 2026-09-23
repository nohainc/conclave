// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;

import 'realtime_client_stub.dart';

class _BrowserRealtimeClient implements RealtimeClient {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  html.WebSocket? _socket;
  Uri? _endpoint;
  String? _workspaceId;
  Timer? _reconnectTimer;
  int _attempt = 0;
  int? _lastDurableSequence;
  bool _closed = false;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<void> connect(Uri endpoint, String workspaceId) async {
    _closed = false;
    _endpoint = endpoint;
    _workspaceId = workspaceId;
    _attempt = 0;
    _open();
  }

  @override
  Future<void> setWorkspace(String workspaceId) async {
    if (_workspaceId == workspaceId) return;
    _send({
      'type': 'unsubscribe',
      'scope': {'workspaceId': _workspaceId},
    });
    _workspaceId = workspaceId;
    _send({
      'type': 'subscribe',
      'scope': {'workspaceId': workspaceId},
    });
  }

  void _open() {
    final endpoint = _endpoint;
    final workspaceId = _workspaceId;
    if (_closed || endpoint == null || workspaceId == null) return;
    final socket = html.WebSocket(endpoint.toString());
    _socket = socket;
    socket.onOpen.listen((_) {
      _attempt = 0;
      _events.add({'type': 'realtime.connection', 'status': 'connected'});
      _send({
        'type': 'realtime.hello',
        if (_lastDurableSequence != null)
          'lastDurableSequence': _lastDurableSequence,
      });
      _send({
        'type': 'subscribe',
        'scope': {'workspaceId': workspaceId},
      });
    });
    socket.onMessage.listen((event) {
      final data = event.data;
      if (data is! String) return;
      try {
        final decoded = jsonDecode(data);
        if (decoded is! Map) return;
        final message = Map<String, dynamic>.from(decoded);
        if (message['type'] == 'event' && message['event'] is Map) {
          final eventValue = Map<String, dynamic>.from(message['event'] as Map);
          final sequence = eventValue['sequence'];
          if (sequence is int) _lastDurableSequence = sequence;
          _events.add(eventValue);
        } else if (message['type'] == 'reconnect.required') {
          // The App performs an authenticated HTTP snapshot resync before
          // continuing to render after a durable event gap.
          _events.add(message);
        }
      } on FormatException {
        // Ignore malformed server frames; reconnect handling remains intact.
      }
    });
    socket.onClose.listen((_) => _scheduleReconnect());
    socket.onError.listen((_) => _scheduleReconnect());
  }

  void _scheduleReconnect() {
    if (_closed || _reconnectTimer?.isActive == true) return;
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
    _reconnectTimer?.cancel();
    _socket?.close();
    await _events.close();
  }
}

RealtimeClient createRealtimeClient() => _BrowserRealtimeClient();
