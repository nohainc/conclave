/// The runtime-side Thread filesystem contract.
///
/// This is intentionally an identity contract, not a path resolver.
/// Work Root configuration and safe path resolution are layered on top of it.
class ThreadFilesystemIdentity {
  const ThreadFilesystemIdentity({
    required this.spaceId,
    required this.threadId,
  });

  final String spaceId;
  final String threadId;

  void validate() {
    if (spaceId.trim().isEmpty) {
      throw const ThreadFilesystemViolation('spaceId is required');
    }
    if (threadId.trim().isEmpty) {
      throw const ThreadFilesystemViolation('threadId is required');
    }
  }

  /// A logical identity key, never a filesystem path.
  String get key {
    validate();
    return '${spaceId.length}:$spaceId${threadId.length}:$threadId';
  }
}

class ThreadFilesystemViolation implements Exception {
  const ThreadFilesystemViolation(this.message);

  final String message;

  @override
  String toString() => 'ThreadFilesystemViolation: $message';
}

/// Values shared by runtime path, CWD, and mutation-lock phases.
abstract final class ThreadFilesystemInvariants {
  static const runtimeCardinality = 'one_per_os_user_installation';
  static const workRootOwnership = 'workspace_runtime_local';
  static const workerCwd = 'runtime_resolved';
  static const repositories = 'worker_managed';
  static const mutation = 'one_per_thread';
  static const parallelism = 'different_threads';
  static const directoryIdentity = <String>['spaceId', 'threadId'];
  static const forbiddenPathComponents = <String>[
    'spaceName',
    'threadName',
    'userEmail',
    'userDisplayName',
    'workspaceId',
    'workerName',
    'repositoryName',
  ];
}
