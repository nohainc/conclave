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

class LocalIpcServer {
  LocalIpcServer({
    required this.token,
    this.bindPort = 0,
    this.onCommand,
  });

  final String token;
  final int bindPort;
  final LocalIpcCommandHandler? onCommand;
  ServerSocket? _server;
  final _messages = StreamController<LocalIpcMessage>.broadcast();

  Stream<LocalIpcMessage> get messages => _messages.stream;
  int? get port => _server?.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, bindPort);
    _server!.listen(_handleClient);
  }

  Future<void> _handleClient(Socket socket) async {
    var authenticated = false;
    var buffer = '';
    socket.listen((bytes) {
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
    }, onDone: socket.destroy);
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
    await _messages.close();
  }
}
