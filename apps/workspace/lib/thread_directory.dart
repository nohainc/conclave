import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'thread_marker.dart';
import 'thread_path.dart';
import 'thread_repository_observability.dart';

/// A stable lock outside the deletable Thread directory. Windows cannot
/// rename a directory while a file inside it remains open and locked.
File threadMutationLockFile({
  required Directory workRoot,
  required String spaceId,
  required String threadId,
}) =>
    File('${workRoot.path}${Platform.pathSeparator}.conclave-mutation-locks'
        '${Platform.pathSeparator}$spaceId${Platform.pathSeparator}'
        '$threadId.lock');

const threadWorkspaceChangeWarning =
    'Local files are not transferred automatically. Commit/push or otherwise '
    'preserve required state before continuing on another Workspace.';

/// User-facing policy for moving mutable Thread execution to another
/// physical Workspace.
class ThreadWorkspaceChangePolicy {
  const ThreadWorkspaceChangePolicy();

  String? warning({required bool hasLocalMutableState}) =>
      hasLocalMutableState ? threadWorkspaceChangeWarning : null;
}

/// Lazy local directory lifecycle.
///
/// Call this only after an executable Work Request has been authorized. It is
/// intentionally not part of Space, Thread, or Discussion creation.
class ThreadDirectoryLifecycle {
  const ThreadDirectoryLifecycle({
    required ThreadPathResolver pathResolver,
    ThreadMarkerStore markerStore = const ThreadMarkerStore(),
    ThreadRepositoryDiscovery repositoryDiscovery =
        const ThreadRepositoryDiscovery(),
  })  : _pathResolver = pathResolver,
        _markerStore = markerStore,
        _repositoryDiscovery = repositoryDiscovery;

  final ThreadPathResolver _pathResolver;
  final ThreadMarkerStore _markerStore;
  final ThreadRepositoryDiscovery _repositoryDiscovery;

  /// Inspects an existing Thread directory without creating local state.
  ///
  /// The path is resolved from immutable IDs and the marker is validated
  /// before any repository metadata is read. A missing directory means that
  /// the Thread has not executed on this Workspace yet.
  Future<List<ThreadRepositoryInfo>> inspectRepositories({
    required String spaceId,
    required String threadId,
  }) async {
    final candidate = await _pathResolver.resolve(
      spaceId: spaceId,
      threadId: threadId,
    );
    if (!await candidate.exists()) return const [];
    await _markerStore.reuse(
      threadDirectory: candidate,
      spaceId: spaceId,
      threadId: threadId,
    );
    return _repositoryDiscovery.discover(candidate);
  }

  /// Ensures the persistent local directory for executable Work exists.
  ///
  /// Existing directories must already have a matching identity marker. A
  /// newly created directory is marked before it is returned to the caller.
  Future<Directory> ensureForExecution({
    required String spaceId,
    required String threadId,
    DateTime? createdAt,
  }) async {
    final candidate = await _pathResolver.resolve(
      spaceId: spaceId,
      threadId: threadId,
    );
    final existed = await candidate.exists();

    if (existed) {
      await _markerStore.reuse(
        threadDirectory: candidate,
        spaceId: spaceId,
        threadId: threadId,
      );
      return candidate;
    }

    try {
      await candidate.create(recursive: true);
      final created = await _pathResolver.resolve(
        spaceId: spaceId,
        threadId: threadId,
      );
      await _markerStore.create(
        threadDirectory: created,
        spaceId: spaceId,
        threadId: threadId,
        createdAt: createdAt,
      );
      return created;
    } on ThreadMarkerViolation {
      // Another runtime may have completed the same first-use race. Reuse is
      // allowed only if the resulting marker validates exactly.
      final created = await _pathResolver.resolve(
        spaceId: spaceId,
        threadId: threadId,
      );
      await _markerStore.reuse(
        threadDirectory: created,
        spaceId: spaceId,
        threadId: threadId,
      );
      return created;
    } on FileSystemException catch (error) {
      throw ThreadDirectoryViolation(
          'Could not create the Thread directory: ${error.message}');
    }
  }
}

class ThreadDirectoryViolation implements Exception {
  const ThreadDirectoryViolation(this.message);

  final String message;

  @override
  String toString() => 'ThreadDirectoryViolation: $message';
}

/// Serializes stateful mutation per Thread directory.
///
/// OS file locking releases the stable Work Root lock when a runtime process
/// exits, while the persisted fencing token rejects stale assignments after
/// reconnect or restart. The lock remains outside the Thread directory so
/// explicit cleanup can safely rename that directory on Windows.
class ThreadMutationCoordinator {
  ThreadMutationCoordinator(this.lifecycle);

  final ThreadDirectoryLifecycle lifecycle;
  final _localTails = <String, Future<void>>{};

  Future<T> withMutation<T>({
    required String spaceId,
    required String threadId,
    required String leaseId,
    required int fencingToken,
    required Future<T> Function(Directory directory) action,
  }) async {
    if (leaseId.trim().isEmpty || fencingToken <= 0) {
      throw const ThreadMutationViolation(
          'leaseId and positive fencingToken are required');
    }
    final key = '$spaceId\u0000$threadId';
    final previous = _localTails[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _localTails[key] = gate.future;
    try {
      try {
        await previous;
      } catch (_) {
        // A failed predecessor must not permanently block the Thread.
      }
      final candidate = await lifecycle._pathResolver.resolve(
        spaceId: spaceId,
        threadId: threadId,
      );
      final lockFile = threadMutationLockFile(
        workRoot: Directory(Directory(candidate.path).parent.parent.path),
        spaceId: spaceId,
        threadId: threadId,
      );
      await lockFile.parent.create(recursive: true);
      final handle = await lockFile.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive);
        final directory = await lifecycle.ensureForExecution(
          spaceId: spaceId,
          threadId: threadId,
        );
        await _validateAndRecordFence(
          directory,
          leaseId: leaseId,
          fencingToken: fencingToken,
        );
        return await action(directory);
      } on ThreadMutationViolation {
        rethrow;
      } on FileSystemException catch (error) {
        throw ThreadMutationViolation(
            'Could not acquire the Thread mutation lock: ${error.message}');
      } finally {
        try {
          await handle.unlock();
        } finally {
          await handle.close();
        }
      }
    } finally {
      gate.complete();
      if (identical(_localTails[key], gate.future)) {
        _localTails.remove(key);
      }
    }
  }

  Future<void> _validateAndRecordFence(
    Directory directory, {
    required String leaseId,
    required int fencingToken,
  }) async {
    final fenceFile =
        File(_join(directory.path, '.conclave-thread-fence.json'));
    Map<String, Object?>? previous;
    if (await fenceFile.exists()) {
      try {
        final decoded = jsonDecode(await fenceFile.readAsString());
        if (decoded is! Map) throw const FormatException();
        previous = Map<String, Object?>.from(decoded);
      } on FormatException {
        throw const ThreadMutationViolation(
            'Thread fencing metadata is invalid');
      } on FileSystemException catch (error) {
        throw ThreadMutationViolation(
            'Thread fencing metadata could not be read: ${error.message}');
      }
    }
    if (previous != null) {
      final previousToken = previous['fencingToken'];
      final previousLease = previous['leaseId'];
      if (previousToken is! int || previousLease is! String) {
        throw const ThreadMutationViolation(
            'Thread fencing metadata is invalid');
      }
      if (fencingToken < previousToken ||
          (fencingToken == previousToken && leaseId != previousLease)) {
        throw const ThreadMutationViolation(
            'stale or conflicting Thread fencing token');
      }
    }
    final temporary =
        File('${fenceFile.path}.tmp-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await temporary.writeAsString(
        jsonEncode({
          'leaseId': leaseId,
          'fencingToken': fencingToken,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
      await temporary.rename(fenceFile.path);
    } on FileSystemException catch (error) {
      throw ThreadMutationViolation(
          'Thread fencing metadata could not be written: ${error.message}');
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  String _join(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';
}

class ThreadMutationViolation implements Exception {
  const ThreadMutationViolation(this.message);

  final String message;

  @override
  String toString() => 'ThreadMutationViolation: $message';
}
