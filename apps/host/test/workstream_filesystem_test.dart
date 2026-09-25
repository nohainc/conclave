import 'package:conclave_host/workstream_filesystem.dart';
import 'package:test/test.dart';

void main() {
  test('freezes the WD-0 identity and ownership model', () {
    expect(WorkstreamFilesystemInvariants.runtimeCardinality,
        'one_per_os_user_installation');
    expect(WorkstreamFilesystemInvariants.workRootOwnership,
        'workspace_runtime_local');
    expect(WorkstreamFilesystemInvariants.directoryIdentity,
        ['projectId', 'workstreamId']);
    expect(WorkstreamFilesystemInvariants.workerCwd, 'runtime_resolved');
    expect(WorkstreamFilesystemInvariants.repositories, 'worker_managed');
    expect(WorkstreamFilesystemInvariants.mutation, 'one_per_workstream');
    expect(WorkstreamFilesystemInvariants.parallelism, 'different_workstreams');
    expect(
        WorkstreamFilesystemInvariants.forbiddenPathComponents,
        containsAll([
          'projectName',
          'workstreamName',
          'workspaceId',
          'repositoryName'
        ]));
  });

  test('identity key is stable across renames and Workspace re-enrollment', () {
    const identity = WorkstreamFilesystemIdentity(
      projectId: 'project-1',
      workstreamId: 'stream-1',
    );
    expect(identity.key, '9:project-18:stream-1');
    expect(
      const WorkstreamFilesystemIdentity(
        projectId: 'project-1',
        workstreamId: 'stream-1',
      ).key,
      identity.key,
    );
  });

  test('rejects missing logical IDs before path resolution', () {
    expect(
      () => const WorkstreamFilesystemIdentity(projectId: '', workstreamId: 's')
          .validate(),
      throwsA(isA<WorkstreamFilesystemViolation>()),
    );
    expect(
      () =>
          const WorkstreamFilesystemIdentity(projectId: 'p', workstreamId: ' ')
              .validate(),
      throwsA(isA<WorkstreamFilesystemViolation>()),
    );
  });
}
