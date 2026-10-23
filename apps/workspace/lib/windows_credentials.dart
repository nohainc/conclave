import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'windows_native.dart';

/// Ciphertext only; Windows DPAPI binds each value to this OS user and account.
class WindowsCredentials {
  WindowsCredentials(this.directory);
  final Directory directory;
  File _file(String service, String key) => File(
      '${directory.path}/${sha256.convert(utf8.encode('$service\u0000$key'))}.dpapi');
  String? read(String service, String key) {
    final file = _file(service, key);
    if (!file.existsSync()) return null;
    if (file.lengthSync() > 1024 * 1024) {
      throw StateError('Credential file exceeds limit');
    }
    WindowsNative.securePath(directory.path);
    WindowsNative.securePath(file.path);
    return utf8.decode(WindowsNative.protect(
        file.readAsBytesSync(), '$service\u0000$key',
        decrypt: true));
  }

  void write(String service, String key, String value) {
    directory.createSync(recursive: true);
    WindowsNative.securePath(directory.path);
    final file = _file(service, key);
    final temporary = File('${file.path}.$pid.tmp');
    try {
      temporary.writeAsBytesSync(
          WindowsNative.protect(utf8.encode(value), '$service\u0000$key'),
          flush: true);
      WindowsNative.securePath(temporary.path);
      temporary.renameSync(file.path);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  void delete(String service, String key) {
    final file = _file(service, key);
    if (file.existsSync()) file.deleteSync();
  }
}
