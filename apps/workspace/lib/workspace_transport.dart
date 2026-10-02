import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Carrier for versioned Workspace runtime messages. Protocol handling lives
/// above this interface and receives the same messages from either transport.
abstract interface class WorkspaceTransport {
  Stream<Object?> get messages;
  void send(Object message);
  Future<void> close();
}

typedef WorkspaceTransportFactory = Future<WorkspaceTransport> Function(
    Uri uri);

String _newRuntimeEventId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex =
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return 'evt-${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20, 32)}';
}

/// HTTPS implementation of the runtime session, event, and long-poll contract.
/// Cloud owns validation and cursor ordering; this adapter treats cursors as
/// opaque values and forwards the common WorkspaceRuntimeMessage unchanged.
class HttpLongPollWorkspaceTransport implements WorkspaceTransport {
  HttpLongPollWorkspaceTransport({
    required this.baseUri,
    required this.workspaceRuntimeId,
    required this.runtimeCredential,
    HttpClient? client,
    this.pollWait = const Duration(seconds: 25),
  }) : _client = client ?? HttpClient();

  final Uri baseUri;
  final String workspaceRuntimeId;
  final String runtimeCredential;
  final Duration pollWait;
  final HttpClient _client;
  final _messages = StreamController<Object?>();
  final _pendingSends = <Future<void>>[];
  Future<void> _sendChain = Future<void>.value();
  String? _sessionId;
  String? _cursor;
  bool _closed = false;
  bool _polling = false;

  @override
  Stream<Object?> get messages => _messages.stream;

  static Future<HttpLongPollWorkspaceTransport> connect({
    required Uri baseUri,
    required String workspaceRuntimeId,
    required String runtimeCredential,
    HttpClient? client,
    Duration pollWait = const Duration(seconds: 25),
  }) async {
    final transport = HttpLongPollWorkspaceTransport(
      baseUri: baseUri,
      workspaceRuntimeId: workspaceRuntimeId,
      runtimeCredential: runtimeCredential,
      client: client,
      pollWait: pollWait,
    );
    try {
      final response =
          await transport._post('/api/workspace-runtime/sessions', {
        'workspaceRuntimeId': workspaceRuntimeId,
        'contractVersion': '1.0',
      });
      transport._sessionId = _requiredString(response, 'sessionId');
      transport._cursor = _requiredString(response, 'cursor');
      unawaited(transport._poll());
      return transport;
    } on Object {
      transport._client.close(force: true);
      await transport._messages.close();
      rethrow;
    }
  }

  @override
  void send(Object message) {
    if (_closed || _sessionId == null) return;
    final decoded = message is String ? jsonDecode(message) : message;
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
          'Workspace transport message must be a JSON object');
    }
    final event = <String, Object?>{
      'contract': 'conclave.desktop-auth-transport',
      'version': '1.0',
      'eventId': _newRuntimeEventId(),
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
      'message': decoded,
    };
    final sessionId = _sessionId!;
    final send = _sendChain
        .then((_) => _post('/api/workspace-runtime/events', {
              'sessionId': sessionId,
              'events': [event],
            }))
        .then<void>((_) {})
        .catchError((Object error, StackTrace stack) {
      if (!_closed) _messages.addError(error, stack);
    });
    _sendChain = send;
    _pendingSends.add(send);
    unawaited(send.whenComplete(() => _pendingSends.remove(send)));
  }

  Future<void> _poll() async {
    if (_polling || _closed) return;
    _polling = true;
    try {
      while (!_closed) {
        final response = await _post('/api/workspace-runtime/poll', {
          'sessionId': _sessionId,
          'cursor': _cursor,
          'waitMs': pollWait.inMilliseconds.clamp(1000, 60000),
        });
        _cursor = _requiredString(response, 'cursor');
        final events = response['events'];
        if (events is List) {
          for (final event in events) {
            if (event is Map && event['message'] is Map && !_closed) {
              _messages.add(jsonEncode(event['message']));
            }
          }
          if (events.isEmpty && response['timedOut'] != true && !_closed) {
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
        }
      }
    } on Object catch (error, stack) {
      if (!_closed) {
        _messages.addError(error, stack);
        await _messages.close();
      }
    } finally {
      _polling = false;
    }
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, Object?> body) async {
    final uri = baseUri.replace(
      scheme: baseUri.scheme == 'https' ? 'https' : 'http',
      path: '${baseUri.path.replaceFirst(RegExp(r'/$'), '')}$path',
      query: null,
      fragment: null,
    );
    final request =
        await _client.postUrl(uri).timeout(const Duration(seconds: 35));
    request.headers.contentType = ContentType.json;
    request.headers
        .set(HttpHeaders.authorizationHeader, 'Bearer $runtimeCredential');
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 65));
    final text = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 65));
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      decoded = null;
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        decoded is! Map) {
      throw HttpException(
          'Workspace runtime HTTPS transport failed (HTTP ${response.statusCode})');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static String _requiredString(Map<String, dynamic> response, String key) {
    final value = response[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Workspace transport response is missing $key');
    }
    return value;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final sessionId = _sessionId;
    if (sessionId != null) {
      try {
        await _post(
            '/api/workspace-runtime/sessions/${Uri.encodeComponent(sessionId)}/close',
            {
              'sessionId': sessionId,
            });
      } on Object {
        // Closing the local poll loop must not depend on Cloud availability.
      }
    }
    await Future.wait(_pendingSends.map((send) => send.catchError((_) {})));
    _client.close(force: true);
    if (!_messages.isClosed) await _messages.close();
  }
}
