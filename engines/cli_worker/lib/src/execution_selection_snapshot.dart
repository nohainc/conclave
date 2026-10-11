import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

/// Internal audit evidence. Native identifiers never enter public inventory.
class ExecutionSelectionSnapshotStore {
  const ExecutionSelectionSnapshotStore(this.statePath);
  final String statePath;

  Future<void> write(
    String invocationId,
    Map<String, Object?> snapshot, {
    bool completion = false,
  }) async {
    final directory = Directory('$statePath/execution-selections');
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const FormatException('Unsafe execution snapshot directory');
    }
    await directory.create(recursive: true);
    final key = sha256.convert(utf8.encode(invocationId)).toString();
    final file = File(
      '${directory.path}/$key${completion ? '.completion' : ''}.json',
    );
    final lock = File('${file.path}.lock');
    final lockType = await FileSystemEntity.type(lock.path, followLinks: false);
    if (lockType != FileSystemEntityType.notFound &&
        lockType != FileSystemEntityType.file) {
      throw const FormatException('Unsafe execution snapshot lock');
    }
    final handle = await lock.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.blockingExclusive);
      final fileType = await FileSystemEntity.type(
        file.path,
        followLinks: false,
      );
      final bytes = jsonEncode(snapshot);
      if (utf8.encode(bytes).length > 16 * 1024) {
        throw const FormatException('Execution snapshot exceeds limit');
      }
      if (fileType == FileSystemEntityType.file) {
        if (await file.length() > 16 * 1024) {
          throw const FormatException(
            'Stored execution snapshot exceeds limit',
          );
        }
        if (await file.readAsString() != bytes) {
          throw const FormatException('Execution snapshot cannot be changed');
        }
        return;
      }
      if (fileType != FileSystemEntityType.notFound) {
        throw const FormatException('Unsafe execution snapshot file');
      }
      final temporary = File(
        '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      await temporary.writeAsString(bytes, flush: true);
      await temporary.rename(file.path);
    } finally {
      await handle.close();
    }
  }
}
