import 'dart:convert';
import 'dart:io';

/// Stable, non-secret identity stored inside a Thread directory.
class ThreadIdentityMarker {
  const ThreadIdentityMarker({
    required this.schemaVersion,
    required this.spaceId,
    required this.threadId,
    required this.createdAt,
  });

  static const currentSchemaVersion = 1;
  static const fileName = '.conclave-thread.json';

  final int schemaVersion;
  final String spaceId;
  final String threadId;
  final DateTime createdAt;

  Map<String, Object> toJson() => {
        'schemaVersion': schemaVersion,
        'spaceId': spaceId,
        'threadId': threadId,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  static ThreadIdentityMarker fromJson(Object? value) {
    if (value is! Map) {
      throw const ThreadMarkerViolation('Marker must contain a JSON object');
    }

    final schemaVersion = value['schemaVersion'];
    final spaceId = value['spaceId'];
    final threadId = value['threadId'];
    final createdAt = value['createdAt'];
    const requiredFields = {
      'schemaVersion',
      'spaceId',
      'threadId',
      'createdAt',
    };
    if (value.keys
        .any((key) => key is! String || !requiredFields.contains(key))) {
      throw const ThreadMarkerViolation('Marker contains unsupported fields');
    }
    if (schemaVersion is! int ||
        spaceId is! String ||
        threadId is! String ||
        createdAt is! String) {
      throw const ThreadMarkerViolation('Marker fields are invalid');
    }
    if (schemaVersion != currentSchemaVersion) {
      throw ThreadMarkerViolation(
          'Unsupported marker schema version: $schemaVersion');
    }
    _validateId(spaceId, 'spaceId');
    _validateId(threadId, 'threadId');

    final timestamp = DateTime.tryParse(createdAt);
    if (timestamp == null || !timestamp.isUtc) {
      throw const ThreadMarkerViolation(
          'Marker createdAt must be a UTC timestamp');
    }
    return ThreadIdentityMarker(
      schemaVersion: schemaVersion,
      spaceId: spaceId,
      threadId: threadId,
      createdAt: timestamp,
    );
  }

  static void _validateId(String value, String field) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$').hasMatch(value)) {
      throw ThreadMarkerViolation(
          '$field must be a safe immutable Cloud ID path component');
    }
  }
}

/// Creates and validates the identity marker without adopting unknown data.
class ThreadMarkerStore {
  const ThreadMarkerStore();

  Future<ThreadIdentityMarker> create({
    required Directory threadDirectory,
    required String spaceId,
    required String threadId,
    DateTime? createdAt,
  }) async {
    await _requireDirectory(threadDirectory);
    final entries = await threadDirectory.list(followLinks: false).toList();
    if (entries.isNotEmpty) {
      throw const ThreadMarkerViolation(
          'Cannot initialize a non-empty Thread directory');
    }

    final marker = ThreadIdentityMarker(
      schemaVersion: ThreadIdentityMarker.currentSchemaVersion,
      spaceId: spaceId,
      threadId: threadId,
      createdAt: (createdAt ?? DateTime.now().toUtc()).toUtc(),
    );
    ThreadIdentityMarker._validateId(spaceId, 'spaceId');
    ThreadIdentityMarker._validateId(threadId, 'threadId');
    await _writeAtomically(threadDirectory, marker);
    return marker;
  }

  Future<ThreadIdentityMarker> reuse({
    required Directory threadDirectory,
    required String spaceId,
    required String threadId,
  }) async {
    await _requireDirectory(threadDirectory);
    final markerFile = File(_markerPath(threadDirectory));
    if (!await markerFile.exists()) {
      throw const ThreadMarkerViolation(
          'Thread directory has no identity marker; refusing adoption');
    }

    final marker = await _read(markerFile);
    if (marker.spaceId != spaceId || marker.threadId != threadId) {
      throw const ThreadMarkerViolation(
          'Thread identity marker does not match the requested IDs');
    }
    return marker;
  }

  Future<void> _writeAtomically(
      Directory directory, ThreadIdentityMarker marker) async {
    final markerPath = _markerPath(directory);
    final markerFile = File(markerPath);
    final lockFile = File('$markerPath.lock');
    if (await markerFile.exists()) {
      throw const ThreadMarkerViolation(
          'Thread identity marker already exists');
    }

    RandomAccessFile? lock;
    File? temporary;
    var lockAcquired = false;
    try {
      try {
        await lockFile.create(exclusive: true);
        lock = await lockFile.open(mode: FileMode.write);
        lockAcquired = true;
      } on FileSystemException {
        throw const ThreadMarkerViolation(
            'Thread marker creation is already in progress');
      }
      if (await markerFile.exists()) {
        throw const ThreadMarkerViolation(
            'Thread identity marker already exists');
      }

      temporary =
          File('$markerPath.${DateTime.now().microsecondsSinceEpoch}.tmp');
      await temporary.writeAsString(
        '${jsonEncode(marker.toJson())}\n',
        flush: true,
      );
      await temporary.rename(markerPath);
    } on ThreadMarkerViolation {
      rethrow;
    } on FileSystemException catch (error) {
      throw ThreadMarkerViolation(
          'Could not atomically create Thread marker: ${error.message}');
    } finally {
      await lock?.close();
      if (temporary != null && await temporary.exists()) {
        await temporary.delete();
      }
      if (lockAcquired && await lockFile.exists()) {
        await lockFile.delete();
      }
    }
  }

  Future<ThreadIdentityMarker> _read(File markerFile) async {
    try {
      return ThreadIdentityMarker.fromJson(
          jsonDecode(await markerFile.readAsString()));
    } on ThreadMarkerViolation {
      rethrow;
    } on FormatException catch (error) {
      throw ThreadMarkerViolation('Marker JSON is corrupt: ${error.message}');
    } on FileSystemException catch (error) {
      throw ThreadMarkerViolation('Marker could not be read: ${error.message}');
    }
  }

  Future<void> _requireDirectory(Directory directory) async {
    final type =
        await FileSystemEntity.type(directory.path, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      throw const ThreadMarkerViolation(
          'Thread marker requires an existing directory');
    }
  }

  String _markerPath(Directory directory) =>
      '${directory.path}${Platform.pathSeparator}${ThreadIdentityMarker.fileName}';
}

class ThreadMarkerViolation implements Exception {
  const ThreadMarkerViolation(this.message);

  final String message;

  @override
  String toString() => 'ThreadMarkerViolation: $message';
}
