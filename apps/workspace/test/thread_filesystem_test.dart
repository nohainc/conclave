import 'package:conclave_workspace/thread_filesystem.dart';
import 'package:test/test.dart';

void main() {
  test('freezes the Thread filesystem identity and ownership model', () {
    expect(ThreadFilesystemInvariants.runtimeCardinality,
        'one_per_os_user_installation');
    expect(ThreadFilesystemInvariants.workRootOwnership,
        'workspace_runtime_local');
    expect(
        ThreadFilesystemInvariants.directoryIdentity, ['spaceId', 'threadId']);
    expect(ThreadFilesystemInvariants.workerCwd, 'runtime_resolved');
    expect(ThreadFilesystemInvariants.repositories, 'worker_managed');
    expect(ThreadFilesystemInvariants.mutation, 'one_per_thread');
    expect(ThreadFilesystemInvariants.parallelism, 'different_threads');
    expect(
        ThreadFilesystemInvariants.forbiddenPathComponents,
        containsAll(
            ['spaceName', 'threadName', 'workspaceId', 'repositoryName']));
  });

  test('identity key is stable across renames and Workspace re-enrollment', () {
    const identity = ThreadFilesystemIdentity(
      spaceId: 'space-1',
      threadId: 'stream-1',
    );
    expect(identity.key, '7:space-18:stream-1');
    expect(
      const ThreadFilesystemIdentity(
        spaceId: 'space-1',
        threadId: 'stream-1',
      ).key,
      identity.key,
    );
  });

  test('rejects missing logical IDs before path resolution', () {
    expect(
      () =>
          const ThreadFilesystemIdentity(spaceId: '', threadId: 's').validate(),
      throwsA(isA<ThreadFilesystemViolation>()),
    );
    expect(
      () => const ThreadFilesystemIdentity(spaceId: 'p', threadId: ' ')
          .validate(),
      throwsA(isA<ThreadFilesystemViolation>()),
    );
  });
}
