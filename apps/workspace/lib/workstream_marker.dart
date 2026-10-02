import 'dart:convert';
import 'dart:io';

/// Stable, non-secret identity stored inside a Workstream directory.
class WorkstreamIdentityMarker {
  const WorkstreamIdentityMarker({
    required this.schemaVersion,
    required this.projectId,
    required this.workstreamId,
    required this.createdAt,
  });

  static const currentSchemaVersion = 1;
  static const fileName = '.conclave-workstream.json';

  final int schemaVersion;
  final String projectId;
  final String workstreamId;
  final DateTime createdAt;

  Map<String, Object> toJson() => {
        'schemaVersion': schemaVersion,
        'projectId': projectId,
        'workstreamId': workstreamId,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  static WorkstreamIdentityMarker fromJson(Object? value) {
    if (value is! Map) {
      throw const WorkstreamMarkerViolation(
          'Marker must contain a JSON object');
    }

    final schemaVersion = value['schemaVersion'];
    final projectId = value['projectId'];
    final workstreamId = value['workstreamId'];
    final createdAt = value['createdAt'];
    const requiredFields = {
      'schemaVersion',
      'projectId',
      'workstreamId',
      'createdAt',
    };
    if (value.keys
        .any((key) => key is! String || !requiredFields.contains(key))) {
      throw const WorkstreamMarkerViolation(
          'Marker contains unsupported fields');
    }
    if (schemaVersion is! int ||
        projectId is! String ||
        workstreamId is! String ||
        createdAt is! String) {
      throw const WorkstreamMarkerViolation('Marker fields are invalid');
    }
    if (schemaVersion != currentSchemaVersion) {
      throw WorkstreamMarkerViolation(
          'Unsupported marker schema version: $schemaVersion');
    }
    _validateId(projectId, 'projectId');
    _validateId(workstreamId, 'workstreamId');

    final timestamp = DateTime.tryParse(createdAt);
    if (timestamp == null || !timestamp.isUtc) {
      throw const WorkstreamMarkerViolation(
          'Marker createdAt must be a UTC timestamp');
    }
    return WorkstreamIdentityMarker(
      schemaVersion: schemaVersion,
      projectId: projectId,
      workstreamId: workstreamId,
      createdAt: timestamp,
    );
  }

  static void _validateId(String value, String field) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$').hasMatch(value)) {
      throw WorkstreamMarkerViolation(
          '$field must be a safe immutable Cloud ID path component');
    }
  }
}

/// Creates and validates the identity marker without adopting unknown data.
class WorkstreamMarkerStore {
  const WorkstreamMarkerStore();

  Future<WorkstreamIdentityMarker> create({
    required Directory workstreamDirectory,
    required String projectId,
    required String workstreamId,
    DateTime? createdAt,
  }) async {
    await _requireDirectory(workstreamDirectory);
    final entries = await workstreamDirectory.list(followLinks: false).toList();
    if (entries.isNotEmpty) {
      throw const WorkstreamMarkerViolation(
          'Cannot initialize a non-empty Workstream directory');
    }

    final marker = WorkstreamIdentityMarker(
      schemaVersion: WorkstreamIdentityMarker.currentSchemaVersion,
      projectId: projectId,
      workstreamId: workstreamId,
      createdAt: (createdAt ?? DateTime.now().toUtc()).toUtc(),
    );
    WorkstreamIdentityMarker._validateId(projectId, 'projectId');
    WorkstreamIdentityMarker._validateId(workstreamId, 'workstreamId');
    await _writeAtomically(workstreamDirectory, marker);
    return marker;
  }

  Future<WorkstreamIdentityMarker> reuse({
    required Directory workstreamDirectory,
    required String projectId,
    required String workstreamId,
  }) async {
    await _requireDirectory(workstreamDirectory);
    final markerFile = File(_markerPath(workstreamDirectory));
    if (!await markerFile.exists()) {
      throw const WorkstreamMarkerViolation(
          'Workstream directory has no identity marker; refusing adoption');
    }

    final marker = await _read(markerFile);
    if (marker.projectId != projectId || marker.workstreamId != workstreamId) {
      throw const WorkstreamMarkerViolation(
          'Workstream identity marker does not match the requested IDs');
    }
    return marker;
  }

  Future<void> _writeAtomically(
      Directory directory, WorkstreamIdentityMarker marker) async {
    final markerPath = _markerPath(directory);
    final markerFile = File(markerPath);
    final lockFile = File('$markerPath.lock');
    if (await markerFile.exists()) {
      throw const WorkstreamMarkerViolation(
          'Workstream identity marker already exists');
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
        throw const WorkstreamMarkerViolation(
            'Workstream marker creation is already in progress');
      }
      if (await markerFile.exists()) {
        throw const WorkstreamMarkerViolation(
            'Workstream identity marker already exists');
      }

      temporary =
          File('$markerPath.${DateTime.now().microsecondsSinceEpoch}.tmp');
      await temporary.writeAsString(
        '${jsonEncode(marker.toJson())}\n',
        flush: true,
      );
      await temporary.rename(markerPath);
    } on WorkstreamMarkerViolation {
      rethrow;
    } on FileSystemException catch (error) {
      throw WorkstreamMarkerViolation(
          'Could not atomically create Workstream marker: ${error.message}');
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

  Future<WorkstreamIdentityMarker> _read(File markerFile) async {
    try {
      return WorkstreamIdentityMarker.fromJson(
          jsonDecode(await markerFile.readAsString()));
    } on WorkstreamMarkerViolation {
      rethrow;
    } on FormatException catch (error) {
      throw WorkstreamMarkerViolation(
          'Marker JSON is corrupt: ${error.message}');
    } on FileSystemException catch (error) {
      throw WorkstreamMarkerViolation(
          'Marker could not be read: ${error.message}');
    }
  }

  Future<void> _requireDirectory(Directory directory) async {
    final type =
        await FileSystemEntity.type(directory.path, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      throw const WorkstreamMarkerViolation(
          'Workstream marker requires an existing directory');
    }
  }

  String _markerPath(Directory directory) =>
      '${directory.path}${Platform.pathSeparator}${WorkstreamIdentityMarker.fileName}';
}

class WorkstreamMarkerViolation implements Exception {
  const WorkstreamMarkerViolation(this.message);

  final String message;

  @override
  String toString() => 'WorkstreamMarkerViolation: $message';
}
