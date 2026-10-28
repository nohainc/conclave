import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'windows_native.dart';

abstract interface class LocalManagementChannel {
  Stream<List<int>> get input;
  void write(String value);
  Future<void> flush();
  void destroy();
}

class UnixManagementChannel implements LocalManagementChannel {
  UnixManagementChannel(this.socket);
  final Socket socket;
  @override
  Stream<List<int>> get input => socket;
  @override
  void write(String value) => socket.write(value);
  @override
  Future<void> flush() => socket.flush();
  @override
  void destroy() => socket.destroy();
}

String workspaceManagerEndpoint(Directory runtime) {
  if (!Platform.isWindows) return '${runtime.path}/manager.sock';
  final id =
      File('${runtime.parent.path}/installation-id').readAsStringSync().trim();
  if (!RegExp(r'^[A-Za-z0-9._-]{8,128}$').hasMatch(id)) {
    throw StateError('Workspace installation identity is missing or invalid');
  }
  return r'\\.\pipe\syntila-workspace-' + id;
}

/// Enforces the byte bound before decoding or retaining an unterminated frame.
Stream<String> managementLines(Stream<List<int>> input) {
  final pending = <int>[];
  return input
      .cast<List<int>>()
      .transform(StreamTransformer<List<int>, String>.fromHandlers(
        handleData: (chunk, sink) {
          for (final byte in chunk) {
            if (byte == 10) {
              if (pending.isNotEmpty && pending.last == 13) {
                pending.removeLast();
              }
              sink.add(utf8.decode(pending));
              pending.clear();
            } else {
              if (pending.length >= 1024 * 1024) {
                throw const FormatException('IPC frame exceeds byte limit');
              }
              pending.add(byte);
            }
          }
        },
        handleDone: (sink) {
          if (pending.isNotEmpty) {
            sink.addError(const FormatException('Truncated IPC frame'));
          }
          sink.close();
        },
      ));
}

class WindowsPipeChannel implements LocalManagementChannel {
  WindowsPipeChannel(this.handle, {this.server = false}) {
    _reader = _read();
  }
  final int handle;
  final bool server;
  final _input = StreamController<List<int>>();
  late final Future<void> _reader;
  Future<void> _writer = Future.value();
  bool _closed = false;
  @override
  Stream<List<int>> get input => _input.stream;

  static Future<WindowsPipeChannel> connect(String path) async {
    final handle = WindowsNative.connectPipe(path);
    return WindowsPipeChannel(handle);
  }

  Future<void> _read() async {
    final nativeHandle = handle;
    try {
      while (!_closed) {
        final bytes = await WindowsNative.readPipe(nativeHandle);
        if (bytes.isEmpty) break;
        if (!_closed) _input.add(bytes);
      }
    } catch (error, stack) {
      if (!_closed && !_input.isClosed) _input.addError(error, stack);
    } finally {
      if (!_closed) destroy();
      unawaited(_input.close());
    }
  }

  @override
  void write(String value) {
    if (_closed) throw const SocketException('Workspace pipe is closed');
    final bytes = utf8.encode(value);
    final nativeHandle = handle;
    _writer = _writer.then((_) async {
      if (!_closed) {
        await WindowsNative.writePipe(nativeHandle, bytes);
      }
    }).catchError((Object error, StackTrace stack) {
      if (!_closed && !_input.isClosed) _input.addError(error, stack);
      destroy();
    });
  }

  @override
  Future<void> flush() async {
    await _writer;
    if (server && !_closed) {
      final nativeHandle = handle;
      // DisconnectNamedPipe discards unread data. Drain the error response
      // before closing a rejected handshake, with the caller's timeout bound.
      try {
        await Isolate.run(() => WindowsNative.flushPipe(nativeHandle));
      } on Object {
        if (!_closed) rethrow;
      }
    }
  }

  @override
  void destroy() {
    if (_closed) return;
    _closed = true;
    WindowsNative.cancelPipe(handle, server: server);
    unawaited(Future.wait([_reader, _writer])
        .whenComplete(() => WindowsNative.close(handle)));
  }
}

class WindowsPipeListener {
  final _connections = StreamController<LocalManagementChannel>();
  Stream<LocalManagementChannel> get connections => _connections.stream;
  int? _pending;
  bool _closed = false;
  Future<void>? _accepting;

  void start(String path) {
    // Create the first instance synchronously so namespace/DACL failures are
    // startup failures, rather than an apparently healthy but absent endpoint.
    _pending = WindowsNative.createPipe(path, first: true);
    _accepting = _accept(path);
  }

  Future<void> _accept(String path) async {
    try {
      while (!_closed) {
        final handle = _pending!;
        final accepted = await WindowsNative.acceptPipe(handle);
        _pending = null;
        if (_closed || !accepted) {
          WindowsNative.close(handle);
          if (!_closed) throw StateError('Workspace pipe accept failed');
          break;
        }
        // Retain an instance before publishing this connection; another user
        // cannot take over the pipe name between successive connections.
        _pending = WindowsNative.createPipe(path, first: false);
        _connections.add(WindowsPipeChannel(handle, server: true));
      }
    } catch (error, stack) {
      if (!_closed) _connections.addError(error, stack);
    } finally {
      unawaited(_connections.close());
    }
  }

  Future<void> close() async {
    _closed = true;
    final handle = _pending;
    if (handle != null) WindowsNative.cancelPipe(handle, server: true);
    await _accepting;
  }
}
