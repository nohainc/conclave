import 'dart:convert';
import 'dart:io';

/// Local state store shared across Worker versions; never writes to Cloud.
class WorkerSessionStore {
  const WorkerSessionStore(this.directory);

  final Directory directory;

  Future<String?> read(String sessionKey) async {
    final file = _fileFor(sessionKey);
    if (!await file.exists()) return null;
    final value = jsonDecode(await file.readAsString());
    if (value is! Map || value['providerSessionId'] is! String) {
      throw const FormatException('Worker session state is invalid');
    }
    return value['providerSessionId'] as String;
  }

  Future<void> write(String sessionKey, String providerSessionId) async {
    await directory.create(recursive: true);
    final file = _fileFor(sessionKey);
    await file.writeAsString(
      jsonEncode({'providerSessionId': providerSessionId}),
    );
  }

  Future<void> delete(String sessionKey) => _fileFor(sessionKey).delete();

  File _fileFor(String key) {
    if (key.isEmpty ||
        key.length > 256 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(key)) {
      throw const FormatException('session key has an invalid format');
    }
    return File('${directory.path}${Platform.pathSeparator}$key.json');
  }
}
