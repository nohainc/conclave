import 'dart:convert';
import 'dart:io';

import 'thread_marker.dart';
import 'thread_directory.dart';
import 'thread_path.dart';

typedef ThreadActiveCheck = Future<bool> Function(
  ThreadIdentityMarker marker,
);

typedef ThreadCleanupClassification = Future<String> Function(
  ThreadIdentityMarker marker,
);

/// A marker-backed local Thread eligible for an explicit cleanup review.
class ThreadCleanupCandidate {
  const ThreadCleanupCandidate({
    required this.directory,
    required this.marker,
    required this.sizeBytes,
    required this.classification,
  });

  final Directory directory;
  final ThreadIdentityMarker marker;
  final int sizeBytes;

  /// A read-model label such as `archived`, `cloud_deleted`,
  /// `workspace_revoked`, or `unknown`. It never authorizes deletion.
  final String classification;

  String get confirmationText => 'DELETE ${marker.spaceId}/${marker.threadId}';
}

class ThreadCleanupIssue {
  const ThreadCleanupIssue({required this.path, required this.message});

  final String path;
  final String message;
}

class ThreadCleanupScan {
  const ThreadCleanupScan({required this.candidates, required this.issues});

  final List<ThreadCleanupCandidate> candidates;
  final List<ThreadCleanupIssue> issues;
}

/// Lists and deletes local Thread data only after explicit confirmation.
///
/// This service is deliberately not called by normal execution, archive, or
/// Workspace lifecycle code. Cloud deletion, archiving, revocation and app
/// updates retain local data until a user explicitly chooses cleanup.
class ThreadCleanupService {
  const ThreadCleanupService({
    required Directory workRoot,
    required ThreadActiveCheck hasActiveAssignment,
    ThreadPathResolver? pathResolver,
    ThreadMarkerStore markerStore = const ThreadMarkerStore(),
    this.lockWait = const Duration(milliseconds: 250),
  })  : _workRoot = workRoot,
        _hasActiveAssignment = hasActiveAssignment,
        _pathResolver = pathResolver,
        _markerStore = markerStore;

  final Directory _workRoot;
  final ThreadActiveCheck _hasActiveAssignment;
  final ThreadPathResolver? _pathResolver;
  final ThreadMarkerStore _markerStore;
  final Duration lockWait;

  Future<ThreadCleanupScan> scan({
    ThreadCleanupClassification? classify,
  }) async {
    final candidates = <ThreadCleanupCandidate>[];
    final issues = <ThreadCleanupIssue>[];
    final root = await _canonicalRoot();
    final spaces = await _directories(root);
    for (final space in spaces) {
      for (final directory in await _directories(space)) {
        final markerFile = File(
          '${directory.path}${Platform.pathSeparator}${ThreadIdentityMarker.fileName}',
        );
        if (!await markerFile.exists()) continue;
        try {
          final marker = await _readMarker(markerFile);
          final expected = await _resolveExpectedPath(marker);
          if (!_samePath(expected.path, directory.path)) {
            throw const ThreadCleanupViolation(
                'marker identity does not match its ID-derived path');
          }
          candidates.add(ThreadCleanupCandidate(
            directory: directory,
            marker: marker,
            sizeBytes: await _sizeOf(directory),
            classification:
                classify == null ? 'unknown' : await classify(marker),
          ));
        } on ThreadCleanupViolation catch (error) {
          issues.add(ThreadCleanupIssue(
            path: directory.path,
            message: error.message,
          ));
        } on ThreadMarkerViolation catch (error) {
          issues.add(ThreadCleanupIssue(
            path: directory.path,
            message: error.message,
          ));
        } on ThreadPathViolation catch (error) {
          issues.add(ThreadCleanupIssue(
            path: directory.path,
            message: error.message,
          ));
        } on FileSystemException catch (error) {
          issues.add(ThreadCleanupIssue(
            path: directory.path,
            message: 'Could not inspect directory: ${error.message}',
          ));
        }
      }
    }
    candidates.sort((a, b) => a.directory.path.compareTo(b.directory.path));
    return ThreadCleanupScan(candidates: candidates, issues: issues);
  }

  /// Deletes one candidate after the caller has displayed the data-loss
  /// warning and supplied the exact confirmation text.
  Future<void> delete(
    ThreadCleanupCandidate candidate, {
    required String confirmation,
  }) async {
    if (confirmation != candidate.confirmationText) {
      throw const ThreadCleanupViolation(
          'explicit cleanup confirmation does not match the Thread');
    }
    final directory = candidate.directory;
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const ThreadCleanupViolation(
          'Thread directory is missing or is not a directory');
    }
    final marker = await _readMarker(File(
      '${directory.path}${Platform.pathSeparator}${ThreadIdentityMarker.fileName}',
    ));
    if (marker.spaceId != candidate.marker.spaceId ||
        marker.threadId != candidate.marker.threadId) {
      throw const ThreadCleanupViolation(
          'Thread identity changed since the cleanup review');
    }
    final expected = await _resolveExpectedPath(marker);
    if (!_samePath(expected.path, directory.path)) {
      throw const ThreadCleanupViolation(
          'Thread path is not the ID-derived path');
    }
    if (await _hasActiveAssignment(marker)) {
      throw const ThreadCleanupViolation('Thread has an active assignment');
    }

    final lockFile = threadMutationLockFile(
      workRoot: await _canonicalRoot(),
      spaceId: marker.spaceId,
      threadId: marker.threadId,
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
            throw const ThreadCleanupViolation(
                'Thread mutation lock is active');
          }),
        ]);
        lockAcquired = true;
      } on ThreadCleanupViolation {
        rethrow;
      }
      if (await _hasActiveAssignment(marker)) {
        throw const ThreadCleanupViolation(
            'Thread became active during cleanup');
      }
      await _markerStore.reuse(
        threadDirectory: directory,
        spaceId: marker.spaceId,
        threadId: marker.threadId,
      );
      // Move the locked directory out of the ID-derived location before
      // releasing the lock. This is safe on platforms that do not allow an
      // open lock file to be deleted and prevents a new mutation from
      // adopting the path while the confirmed cleanup is finishing.
      tombstone = Directory(
        '${directory.path}.deleting-${DateTime.now().microsecondsSinceEpoch}',
      );
      await directory.rename(tombstone.path);
    } on ThreadCleanupViolation {
      rethrow;
    } on FileSystemException catch (error) {
      throw ThreadCleanupViolation(
          'Could not acquire the Thread cleanup lock: ${error.message}');
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
      throw ThreadCleanupViolation(
          'Thread cleanup was moved aside but could not finish: ${error.message}');
    }
  }

  Future<Directory> _canonicalRoot() async {
    final type =
        await FileSystemEntity.type(_workRoot.path, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      throw const ThreadCleanupViolation('Work Root is not a directory');
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

  Future<ThreadIdentityMarker> _readMarker(File file) async {
    try {
      return ThreadIdentityMarker.fromJson(
          jsonDecode(await file.readAsString()));
    } on ThreadMarkerViolation {
      rethrow;
    } on FormatException catch (error) {
      throw ThreadMarkerViolation('Marker JSON is corrupt: ${error.message}');
    } on FileSystemException catch (error) {
      throw ThreadMarkerViolation('Marker could not be read: ${error.message}');
    }
  }

  Future<Directory> _resolveExpectedPath(
    ThreadIdentityMarker marker,
  ) async {
    final resolver = _pathResolver ?? ThreadPathResolver(_workRoot);
    return resolver.resolve(
      spaceId: marker.spaceId,
      threadId: marker.threadId,
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

class ThreadCleanupViolation implements Exception {
  const ThreadCleanupViolation(this.message);

  final String message;

  @override
  String toString() => 'ThreadCleanupViolation: $message';
}
