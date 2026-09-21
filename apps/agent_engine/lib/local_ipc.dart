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
  const IpcCommand(super.type, super.payload);
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
      : IpcCommand(type, payload);
}

class LocalIpcServer {
  LocalIpcServer({required this.token});

  final String token;
  ServerSocket? _server;
  final _messages = StreamController<LocalIpcMessage>.broadcast();

  Stream<LocalIpcMessage> get messages => _messages.stream;
  int? get port => _server?.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleClient);
  }

  Future<void> _handleClient(Socket socket) async {
    var authenticated = false;
    socket.listen((bytes) {
      for (final line
          in utf8.decode(bytes).split('\n').where((line) => line.isNotEmpty)) {
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
          _messages.add(parseLocalIpcMessage(decoded));
        } on Object {
          socket.writeln(jsonEncode({'ok': false, 'error': 'invalid_message'}));
        }
      }
    }, onDone: socket.destroy);
  }

  Future<void> close() async {
    await _server?.close();
    await _messages.close();
  }
}
