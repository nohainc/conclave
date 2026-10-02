import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'workstream_marker.dart';
import 'workstream_path.dart';
import 'workstream_repository_observability.dart';

/// A stable lock outside the deletable Workstream directory. Windows cannot
/// rename a directory while a file inside it remains open and locked.
File workstreamMutationLockFile({
  required Directory workRoot,
  required String projectId,
  required String workstreamId,
}) =>
    File('${workRoot.path}${Platform.pathSeparator}.conclave-mutation-locks'
        '${Platform.pathSeparator}$projectId${Platform.pathSeparator}'
        '$workstreamId.lock');

const workstreamWorkspaceChangeWarning =
    'Local files are not transferred automatically. Commit/push or otherwise '
    'preserve required state before continuing on another Workspace.';

/// User-facing policy for moving mutable Workstream execution to another
/// physical Workspace.
class WorkstreamWorkspaceChangePolicy {
  const WorkstreamWorkspaceChangePolicy();

  String? warning({required bool hasLocalMutableState}) =>
      hasLocalMutableState ? workstreamWorkspaceChangeWarning : null;
}

/// WD-4 lazy local directory lifecycle.
///
/// Call this only after an executable Work Request has been authorized. It is
/// intentionally not part of Project, Workstream, or Discussion creation.
class WorkstreamDirectoryLifecycle {
  const WorkstreamDirectoryLifecycle({
    required WorkstreamPathResolver pathResolver,
    WorkstreamMarkerStore markerStore = const WorkstreamMarkerStore(),
    WorkstreamRepositoryDiscovery repositoryDiscovery =
        const WorkstreamRepositoryDiscovery(),
  })  : _pathResolver = pathResolver,
        _markerStore = markerStore,
        _repositoryDiscovery = repositoryDiscovery;

  final WorkstreamPathResolver _pathResolver;
  final WorkstreamMarkerStore _markerStore;
  final WorkstreamRepositoryDiscovery _repositoryDiscovery;

  /// Inspects an existing Workstream directory without creating local state.
  ///
  /// The path is resolved from immutable IDs and the marker is validated
  /// before any repository metadata is read. A missing directory means that
  /// the Workstream has not executed on this Workspace yet.
  Future<List<WorkstreamRepositoryInfo>> inspectRepositories({
    required String projectId,
    required String workstreamId,
  }) async {
    final candidate = await _pathResolver.resolve(
      projectId: projectId,
      workstreamId: workstreamId,
    );
    if (!await candidate.exists()) return const [];
    await _markerStore.reuse(
      workstreamDirectory: candidate,
      projectId: projectId,
      workstreamId: workstreamId,
    );
    return _repositoryDiscovery.discover(candidate);
  }

  /// Ensures the persistent local directory for executable Work exists.
  ///
  /// Existing directories must already have a matching identity marker. A
  /// newly created directory is marked before it is returned to the caller.
  Future<Directory> ensureForExecution({
    required String projectId,
    required String workstreamId,
    DateTime? createdAt,
  }) async {
    final candidate = await _pathResolver.resolve(
      projectId: projectId,
      workstreamId: workstreamId,
    );
    final existed = await candidate.exists();

    if (existed) {
      await _markerStore.reuse(
        workstreamDirectory: candidate,
        projectId: projectId,
        workstreamId: workstreamId,
      );
      return candidate;
    }

    try {
      await candidate.create(recursive: true);
      final created = await _pathResolver.resolve(
        projectId: projectId,
        workstreamId: workstreamId,
      );
      await _markerStore.create(
        workstreamDirectory: created,
        projectId: projectId,
        workstreamId: workstreamId,
        createdAt: createdAt,
      );
      return created;
    } on WorkstreamMarkerViolation {
      // Another runtime may have completed the same first-use race. Reuse is
      // allowed only if the resulting marker validates exactly.
      final created = await _pathResolver.resolve(
        projectId: projectId,
        workstreamId: workstreamId,
      );
      await _markerStore.reuse(
        workstreamDirectory: created,
        projectId: projectId,
        workstreamId: workstreamId,
      );
      return created;
    } on FileSystemException catch (error) {
      throw WorkstreamDirectoryViolation(
          'Could not create the Workstream directory: ${error.message}');
    }
  }
}

class WorkstreamDirectoryViolation implements Exception {
  const WorkstreamDirectoryViolation(this.message);

  final String message;

  @override
  String toString() => 'WorkstreamDirectoryViolation: $message';
}

/// Serializes stateful mutation per Workstream directory.
///
/// OS file locking releases the stable Work Root lock when a runtime process
/// exits, while the persisted fencing token rejects stale assignments after
/// reconnect or restart. The lock remains outside the Workstream directory so
/// explicit cleanup can safely rename that directory on Windows.
class WorkstreamMutationCoordinator {
  WorkstreamMutationCoordinator(this.lifecycle);

  final WorkstreamDirectoryLifecycle lifecycle;
  final _localTails = <String, Future<void>>{};

  Future<T> withMutation<T>({
    required String projectId,
    required String workstreamId,
    required String leaseId,
    required int fencingToken,
    required Future<T> Function(Directory directory) action,
  }) async {
    if (leaseId.trim().isEmpty || fencingToken <= 0) {
      throw const WorkstreamMutationViolation(
          'leaseId and positive fencingToken are required');
    }
    final key = '$projectId\u0000$workstreamId';
    final previous = _localTails[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _localTails[key] = gate.future;
    try {
      try {
        await previous;
      } catch (_) {
        // A failed predecessor must not permanently block the Workstream.
      }
      final candidate = await lifecycle._pathResolver.resolve(
        projectId: projectId,
        workstreamId: workstreamId,
      );
      final lockFile = workstreamMutationLockFile(
        workRoot: Directory(Directory(candidate.path).parent.parent.path),
        projectId: projectId,
        workstreamId: workstreamId,
      );
      await lockFile.parent.create(recursive: true);
      final handle = await lockFile.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive);
        final directory = await lifecycle.ensureForExecution(
          projectId: projectId,
          workstreamId: workstreamId,
        );
        await _validateAndRecordFence(
          directory,
          leaseId: leaseId,
          fencingToken: fencingToken,
        );
        return await action(directory);
      } on WorkstreamMutationViolation {
        rethrow;
      } on FileSystemException catch (error) {
        throw WorkstreamMutationViolation(
            'Could not acquire the Workstream mutation lock: ${error.message}');
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
        File(_join(directory.path, '.conclave-workstream-fence.json'));
    Map<String, Object?>? previous;
    if (await fenceFile.exists()) {
      try {
        final decoded = jsonDecode(await fenceFile.readAsString());
        if (decoded is! Map) throw const FormatException();
        previous = Map<String, Object?>.from(decoded);
      } on FormatException {
        throw const WorkstreamMutationViolation(
            'Workstream fencing metadata is invalid');
      } on FileSystemException catch (error) {
        throw WorkstreamMutationViolation(
            'Workstream fencing metadata could not be read: ${error.message}');
      }
    }
    if (previous != null) {
      final previousToken = previous['fencingToken'];
      final previousLease = previous['leaseId'];
      if (previousToken is! int || previousLease is! String) {
        throw const WorkstreamMutationViolation(
            'Workstream fencing metadata is invalid');
      }
      if (fencingToken < previousToken ||
          (fencingToken == previousToken && leaseId != previousLease)) {
        throw const WorkstreamMutationViolation(
            'stale or conflicting Workstream fencing token');
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
      throw WorkstreamMutationViolation(
          'Workstream fencing metadata could not be written: ${error.message}');
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  String _join(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';
}

class WorkstreamMutationViolation implements Exception {
  const WorkstreamMutationViolation(this.message);

  final String message;

  @override
  String toString() => 'WorkstreamMutationViolation: $message';
}
