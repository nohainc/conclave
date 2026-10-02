/// WD-0: the runtime-side Workstream filesystem contract.
///
/// This is intentionally an identity contract, not a path resolver. WD-1 and
/// WD-2 will add Work Root configuration and safe path resolution on top of it.
class WorkstreamFilesystemIdentity {
  const WorkstreamFilesystemIdentity({
    required this.projectId,
    required this.workstreamId,
  });

  final String projectId;
  final String workstreamId;

  void validate() {
    if (projectId.trim().isEmpty) {
      throw const WorkstreamFilesystemViolation('projectId is required');
    }
    if (workstreamId.trim().isEmpty) {
      throw const WorkstreamFilesystemViolation('workstreamId is required');
    }
  }

  /// A logical identity key, never a filesystem path.
  String get key {
    validate();
    return '${projectId.length}:$projectId${workstreamId.length}:$workstreamId';
  }
}

class WorkstreamFilesystemViolation implements Exception {
  const WorkstreamFilesystemViolation(this.message);

  final String message;

  @override
  String toString() => 'WorkstreamFilesystemViolation: $message';
}

/// Values shared by later runtime path, CWD, and mutation-lock phases.
abstract final class WorkstreamFilesystemInvariants {
  static const runtimeCardinality = 'one_per_os_user_installation';
  static const workRootOwnership = 'workspace_runtime_local';
  static const workerCwd = 'runtime_resolved';
  static const repositories = 'worker_managed';
  static const mutation = 'one_per_workstream';
  static const parallelism = 'different_workstreams';
  static const directoryIdentity = <String>['projectId', 'workstreamId'];
  static const forbiddenPathComponents = <String>[
    'projectName',
    'workstreamName',
    'userEmail',
    'userDisplayName',
    'workspaceId',
    'workerName',
    'repositoryName',
  ];
}
