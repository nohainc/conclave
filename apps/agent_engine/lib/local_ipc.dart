import 'dart:async';
import 'dart:convert';
import 'dart:io';

sealed class LocalIpcMessage {
  const LocalIpcMessage(this.type, this.payload);
  final String type;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => {'type': type, 'payload': payload};
}

class IpcCommand extends LocalIpcMessage {
  const IpcCommand(super.type, super.payload, {this.requestId});

  final String? requestId;

  @override
  Map<String, Object?> toJson() => {
        ...super.toJson(),
        if (requestId != null) 'requestId': requestId,
      };
}

class IpcEvent extends LocalIpcMessage {
  const IpcEvent(super.type, super.payload);
}

LocalIpcMessage parseLocalIpcMessage(Object? value) {
  if (value is String) value = jsonDecode(value);
  if (value is! Map || value['type'] is! String || value['payload'] is! Map) {
    throw const FormatException('invalid local IPC message');
  }
  final type = value['type'] as String;
  final payload = Map<String, Object?>.from(value['payload'] as Map);
  return type.startsWith('event.')
      ? IpcEvent(type, payload)
      : IpcCommand(type, payload,
          requestId: value['requestId'] is String
              ? value['requestId'] as String
              : null);
}

typedef LocalIpcCommandHandler = Future<Map<String, Object?>> Function(
  IpcCommand command,
);

class LocalIpcClient {
  LocalIpcClient._(this._socket, this._lines);

  final Socket _socket;
  final StreamIterator<String> _lines;
  int _requestSequence = 0;

  static Future<LocalIpcClient> connect({
    required int port,
    required String token,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: timeout,
    );
    final lines = StreamIterator<String>(
      socket.map((bytes) => bytes.toList()).transform(utf8.decoder).transform(
            const LineSplitter(),
          ),
    );
    socket.writeln(jsonEncode({'token': token}));
    if (!await lines.moveNext().timeout(timeout)) {
      await lines.cancel();
      await socket.close();
      throw const FormatException('local IPC did not acknowledge');
    }
    final acknowledgement = jsonDecode(lines.current);
    if (acknowledgement is! Map || acknowledgement['ok'] != true) {
      await lines.cancel();
      await socket.close();
      throw const FormatException('local IPC authentication failed');
    }
    return LocalIpcClient._(socket, lines);
  }

  Future<Map<String, Object?>> command(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final requestId = 'ipc-${DateTime.now().microsecondsSinceEpoch}-'
        '${++_requestSequence}';
    _socket.writeln(jsonEncode(
      IpcCommand(type, payload, requestId: requestId).toJson(),
    ));
    while (true) {
      if (!await _lines.moveNext().timeout(timeout)) {
        throw StateError('local IPC connection closed');
      }
      final decoded = jsonDecode(_lines.current);
      if (decoded is! Map || decoded['requestId'] != requestId) continue;
      if (decoded['ok'] != true) {
        throw StateError(
          decoded['error']?.toString() ?? 'local IPC command failed',
        );
      }
      final response = decoded['payload'];
      if (response is! Map) {
        throw const FormatException('local IPC response payload is invalid');
      }
      return Map<String, Object?>.from(response);
    }
  }

  Future<void> close() async {
    await _lines.cancel();
    await _socket.close();
  }
}

class LocalIpcServer {
  LocalIpcServer({
    required this.token,
    this.bindPort = 0,
    this.onCommand,
    this.authenticationTimeout = const Duration(seconds: 2),
    this.maxFrameBytes = 1024 * 1024,
  });

  final String token;
  final int bindPort;
  final LocalIpcCommandHandler? onCommand;
  final Duration authenticationTimeout;
  final int maxFrameBytes;
  ServerSocket? _server;
  final _messages = StreamController<LocalIpcMessage>.broadcast();
  final _clients = <Socket>{};

  Stream<LocalIpcMessage> get messages => _messages.stream;
  int? get port => _server?.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, bindPort);
    _server!.listen(_handleClient);
  }

  Future<void> _handleClient(Socket socket) async {
    _clients.add(socket);
    var authenticated = false;
    var buffer = '';
    Timer? authenticationTimer;
    authenticationTimer = Timer(authenticationTimeout, () {
      if (!authenticated) socket.destroy();
    });
    socket.listen((bytes) {
      if (bytes.length > maxFrameBytes ||
          utf8.encode(buffer).length + bytes.length > maxFrameBytes) {
        socket.destroy();
        return;
      }
      buffer += utf8.decode(bytes, allowMalformed: false);
      final lines = buffer.split('\n');
      buffer = lines.removeLast();
      for (final line in lines.where((line) => line.trim().isNotEmpty)) {
        try {
          final decoded = jsonDecode(line);
          if (!authenticated) {
            if (decoded is! Map || decoded['token'] != token) {
              socket.destroy();
              return;
            }
            authenticated = true;
            authenticationTimer?.cancel();
            socket.writeln(jsonEncode({'ok': true}));
            continue;
          }
          final message = parseLocalIpcMessage(decoded);
          _messages.add(message);
          if (message is IpcCommand && onCommand != null) {
            unawaited(_respond(socket, message));
          }
        } on Object {
          socket.writeln(jsonEncode({'ok': false, 'error': 'invalid_message'}));
        }
      }
    }, onDone: () {
      authenticationTimer?.cancel();
      _clients.remove(socket);
      socket.destroy();
    });
  }

  Future<void> _respond(Socket socket, IpcCommand command) async {
    try {
      final payload = await onCommand!(command);
      socket.writeln(jsonEncode({
        'ok': true,
        'requestId': command.requestId,
        'type': command.type,
        'payload': payload,
      }));
    } on Object catch (error) {
      socket.writeln(jsonEncode({
        'ok': false,
        'requestId': command.requestId,
        'type': command.type,
        'error': '$error',
      }));
    }
  }

  Future<void> close() async {
    await _server?.close();
    for (final client in _clients.toList()) {
      client.destroy();
    }
    _clients.clear();
    await _messages.close();
  }
}
