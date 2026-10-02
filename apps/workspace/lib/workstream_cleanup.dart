import 'dart:convert';
import 'dart:io';

import 'workstream_marker.dart';
import 'workstream_directory.dart';
import 'workstream_path.dart';

typedef WorkstreamActiveCheck = Future<bool> Function(
  WorkstreamIdentityMarker marker,
);

typedef WorkstreamCleanupClassification = Future<String> Function(
  WorkstreamIdentityMarker marker,
);

/// A marker-backed local Workstream eligible for an explicit cleanup review.
class WorkstreamCleanupCandidate {
  const WorkstreamCleanupCandidate({
    required this.directory,
    required this.marker,
    required this.sizeBytes,
    required this.classification,
  });

  final Directory directory;
  final WorkstreamIdentityMarker marker;
  final int sizeBytes;

  /// A read-model label such as `archived`, `cloud_deleted`,
  /// `workspace_revoked`, or `unknown`. It never authorizes deletion.
  final String classification;

  String get confirmationText =>
      'DELETE ${marker.projectId}/${marker.workstreamId}';
}

class WorkstreamCleanupIssue {
  const WorkstreamCleanupIssue({required this.path, required this.message});

  final String path;
  final String message;
}

class WorkstreamCleanupScan {
  const WorkstreamCleanupScan({required this.candidates, required this.issues});

  final List<WorkstreamCleanupCandidate> candidates;
  final List<WorkstreamCleanupIssue> issues;
}

/// Lists and deletes local Workstream data only after explicit confirmation.
///
/// This service is deliberately not called by normal execution, archive, or
/// Workspace lifecycle code. Cloud deletion, archiving, revocation and app
/// updates retain local data until a user explicitly chooses cleanup.
class WorkstreamCleanupService {
  const WorkstreamCleanupService({
    required Directory workRoot,
    required WorkstreamActiveCheck hasActiveAssignment,
    WorkstreamPathResolver? pathResolver,
    WorkstreamMarkerStore markerStore = const WorkstreamMarkerStore(),
    this.lockWait = const Duration(milliseconds: 250),
  })  : _workRoot = workRoot,
        _hasActiveAssignment = hasActiveAssignment,
        _pathResolver = pathResolver,
        _markerStore = markerStore;

  final Directory _workRoot;
  final WorkstreamActiveCheck _hasActiveAssignment;
  final WorkstreamPathResolver? _pathResolver;
  final WorkstreamMarkerStore _markerStore;
  final Duration lockWait;

  Future<WorkstreamCleanupScan> scan({
    WorkstreamCleanupClassification? classify,
  }) async {
    final candidates = <WorkstreamCleanupCandidate>[];
    final issues = <WorkstreamCleanupIssue>[];
    final root = await _canonicalRoot();
    final projects = await _directories(root);
    for (final project in projects) {
      for (final directory in await _directories(project)) {
        final markerFile = File(
          '${directory.path}${Platform.pathSeparator}${WorkstreamIdentityMarker.fileName}',
        );
        if (!await markerFile.exists()) continue;
        try {
          final marker = await _readMarker(markerFile);
          final expected = await _resolveExpectedPath(marker);
          if (!_samePath(expected.path, directory.path)) {
            throw const WorkstreamCleanupViolation(
                'marker identity does not match its ID-derived path');
          }
          candidates.add(WorkstreamCleanupCandidate(
            directory: directory,
            marker: marker,
            sizeBytes: await _sizeOf(directory),
            classification:
                classify == null ? 'unknown' : await classify(marker),
          ));
        } on WorkstreamCleanupViolation catch (error) {
          issues.add(WorkstreamCleanupIssue(
            path: directory.path,
            message: error.message,
          ));
        } on WorkstreamMarkerViolation catch (error) {
          issues.add(WorkstreamCleanupIssue(
            path: directory.path,
            message: error.message,
          ));
        } on WorkstreamPathViolation catch (error) {
          issues.add(WorkstreamCleanupIssue(
            path: directory.path,
            message: error.message,
          ));
        } on FileSystemException catch (error) {
          issues.add(WorkstreamCleanupIssue(
            path: directory.path,
            message: 'Could not inspect directory: ${error.message}',
          ));
        }
      }
    }
    candidates.sort((a, b) => a.directory.path.compareTo(b.directory.path));
    return WorkstreamCleanupScan(candidates: candidates, issues: issues);
  }

  /// Deletes one candidate after the caller has displayed the data-loss
  /// warning and supplied the exact confirmation text.
  Future<void> delete(
    WorkstreamCleanupCandidate candidate, {
    required String confirmation,
  }) async {
    if (confirmation != candidate.confirmationText) {
      throw const WorkstreamCleanupViolation(
          'explicit cleanup confirmation does not match the Workstream');
    }
    final directory = candidate.directory;
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const WorkstreamCleanupViolation(
          'Workstream directory is missing or is not a directory');
    }
    final marker = await _readMarker(File(
      '${directory.path}${Platform.pathSeparator}${WorkstreamIdentityMarker.fileName}',
    ));
    if (marker.projectId != candidate.marker.projectId ||
        marker.workstreamId != candidate.marker.workstreamId) {
      throw const WorkstreamCleanupViolation(
          'Workstream identity changed since the cleanup review');
    }
    final expected = await _resolveExpectedPath(marker);
    if (!_samePath(expected.path, directory.path)) {
      throw const WorkstreamCleanupViolation(
          'Workstream path is not the ID-derived path');
    }
    if (await _hasActiveAssignment(marker)) {
      throw const WorkstreamCleanupViolation(
          'Workstream has an active assignment');
    }

    final lockFile = workstreamMutationLockFile(
      workRoot: await _canonicalRoot(),
      projectId: marker.projectId,
      workstreamId: marker.workstreamId,
    );
    RandomAccessFile? lock;
    late Directory tombstone;
    var lockAcquired = false;
    try {
      await lockFile.parent.create(recursive: true);
      lock = await lockFile.open(mode: FileMode.append);
      try {
        await Future.any<void>([
          lock.lock(FileLock.exclusive),
          Future<void>.delayed(lockWait, () {
            throw const WorkstreamCleanupViolation(
                'Workstream mutation lock is active');
          }),
        ]);
        lockAcquired = true;
      } on WorkstreamCleanupViolation {
        rethrow;
      }
      if (await _hasActiveAssignment(marker)) {
        throw const WorkstreamCleanupViolation(
            'Workstream became active during cleanup');
      }
      await _markerStore.reuse(
        workstreamDirectory: directory,
        projectId: marker.projectId,
        workstreamId: marker.workstreamId,
      );
      // Move the locked directory out of the ID-derived location before
      // releasing the lock. This is safe on platforms that do not allow an
      // open lock file to be deleted and prevents a new mutation from
      // adopting the path while the confirmed cleanup is finishing.
      tombstone = Directory(
        '${directory.path}.deleting-${DateTime.now().microsecondsSinceEpoch}',
      );
      await directory.rename(tombstone.path);
    } on WorkstreamCleanupViolation {
      rethrow;
    } on FileSystemException catch (error) {
      throw WorkstreamCleanupViolation(
          'Could not acquire the Workstream cleanup lock: ${error.message}');
    } finally {
      try {
        if (lockAcquired) await lock?.unlock();
      } finally {
        await lock?.close();
      }
    }
    try {
      await tombstone.delete(recursive: true);
    } on FileSystemException catch (error) {
      throw WorkstreamCleanupViolation(
          'Workstream cleanup was moved aside but could not finish: ${error.message}');
    }
  }

  Future<Directory> _canonicalRoot() async {
    final type =
        await FileSystemEntity.type(_workRoot.path, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      throw const WorkstreamCleanupViolation('Work Root is not a directory');
    }
    return Directory(await _workRoot.resolveSymbolicLinks());
  }

  Future<List<Directory>> _directories(Directory parent) async {
    final result = <Directory>[];
    await for (final entry in parent.list(followLinks: false)) {
      if (entry is! Directory) continue;
      if (await FileSystemEntity.type(entry.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        result.add(entry);
      }
    }
    return result;
  }

  Future<WorkstreamIdentityMarker> _readMarker(File file) async {
    try {
      return WorkstreamIdentityMarker.fromJson(
          jsonDecode(await file.readAsString()));
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

  Future<Directory> _resolveExpectedPath(
    WorkstreamIdentityMarker marker,
  ) async {
    final resolver = _pathResolver ?? WorkstreamPathResolver(_workRoot);
    return resolver.resolve(
      projectId: marker.projectId,
      workstreamId: marker.workstreamId,
    );
  }

  Future<int> _sizeOf(Directory directory) async {
    var total = 0;
    await for (final entry
        in directory.list(followLinks: false, recursive: true)) {
      final type = await FileSystemEntity.type(entry.path, followLinks: false);
      if (type != FileSystemEntityType.file) continue;
      try {
        total += await File(entry.path).length();
      } on FileSystemException {
        // A diagnostic size is best effort; inaccessible files do not make
        // the cleanup candidate unsafe to review.
      }
    }
    return total;
  }

  bool _samePath(String left, String right) {
    final a = left.replaceAll('\\', '/').replaceFirst(RegExp(r'/$'), '');
    final b = right.replaceAll('\\', '/').replaceFirst(RegExp(r'/$'), '');
    return Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
  }
}

class WorkstreamCleanupViolation implements Exception {
  const WorkstreamCleanupViolation(this.message);

  final String message;

  @override
  String toString() => 'WorkstreamCleanupViolation: $message';
}
