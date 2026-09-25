import 'dart:io';

import 'package:conclave_host/workstream_directory.dart';
import 'package:conclave_host/workstream_path.dart';
import 'package:conclave_host/workstream_repository_observability.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory workstream;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('conclave-repository-root-');
    final lifecycle = WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(root),
    );
    workstream = await lifecycle.ensureForExecution(
      projectId: 'project-1',
      workstreamId: 'workstream-1',
    );
  });

  tearDown(() => root.delete(recursive: true));

  Future<void> runGit(Directory directory, List<String> arguments) async {
    final result = await Process.run(
      'git',
      arguments,
      workingDirectory: directory.path,
      runInShell: false,
    );
    if (result.exitCode != 0) {
      throw StateError('${result.stdout}\n${result.stderr}');
    }
  }

  test('returns no repositories for an empty Workstream', () async {
    final repositories =
        await const WorkstreamRepositoryDiscovery().discover(workstream);
    expect(repositories, isEmpty);
  });

  test('lifecycle inspection is ID-resolved and does not create a directory',
      () async {
    final lifecycle = WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(root),
    );
    final repositories = await lifecycle.inspectRepositories(
      projectId: 'project-without-work',
      workstreamId: 'workstream-without-work',
    );
    expect(repositories, isEmpty);
    expect(
      await Directory(
        '${root.path}${Platform.pathSeparator}project-without-work',
      ).exists(),
      isFalse,
    );
  });

  test('discovers read-only repository metadata and redacts remote secrets',
      () async {
    final repository =
        Directory('${workstream.path}${Platform.pathSeparator}app');
    await repository.create();
    await runGit(repository, ['init', '-q']);
    await runGit(repository, ['config', 'user.email', 'test@example.com']);
    await runGit(repository, ['config', 'user.name', 'Conclave Test']);
    await runGit(repository, [
      'remote',
      'add',
      'origin',
      'https://user:secret@example.com/nohainc/conclave.git?token=private',
    ]);
    await File('${repository.path}${Platform.pathSeparator}README.md')
        .writeAsString('initial\n');
    await runGit(repository, ['add', 'README.md']);
    await runGit(repository, ['commit', '-qm', 'initial']);
    await File('${repository.path}${Platform.pathSeparator}changed.txt')
        .writeAsString('uncommitted\n');

    final repositories =
        await const WorkstreamRepositoryDiscovery().discover(workstream);
    expect(repositories, hasLength(1));
    final info = repositories.single;
    expect(info.relativePath, 'app');
    expect(info.head, matches(RegExp(r'^[0-9a-f]{40}$')));
    expect(info.branch, isNotEmpty);
    expect(info.dirty, isTrue);
    expect(info.changedFileCount, 1);
    expect(info.remotes.single.name, 'origin');
    expect(info.remotes.single.location, 'example.com/nohainc/conclave.git');
    expect(info.toJson().toString(), isNot(contains('secret')));
    expect(info.toJson().toString(), isNot(contains('token=private')));
  });

  test('does not change branch, HEAD, or remote configuration', () async {
    final repository =
        Directory('${workstream.path}${Platform.pathSeparator}repo');
    await repository.create();
    await runGit(repository, ['init', '-q']);
    await runGit(repository, ['config', 'user.email', 'test@example.com']);
    await runGit(repository, ['config', 'user.name', 'Conclave Test']);
    await File('${repository.path}${Platform.pathSeparator}file.txt')
        .writeAsString('content\n');
    await runGit(repository, ['add', 'file.txt']);
    await runGit(repository, ['commit', '-qm', 'initial']);
    await runGit(repository, [
      'remote',
      'add',
      'origin',
      'git@example.com:nohainc/conclave.git',
    ]);
    final beforeHead = (await Process.run(
      'git',
      ['rev-parse', 'HEAD'],
      workingDirectory: repository.path,
    ))
        .stdout;
    final beforeRemote = (await Process.run(
      'git',
      ['remote', 'get-url', 'origin'],
      workingDirectory: repository.path,
    ))
        .stdout;

    await const WorkstreamRepositoryDiscovery().discover(workstream);

    expect(
      (await Process.run('git', ['rev-parse', 'HEAD'],
              workingDirectory: repository.path))
          .stdout,
      beforeHead,
    );
    expect(
      (await Process.run('git', ['remote', 'get-url', 'origin'],
              workingDirectory: repository.path))
          .stdout,
      beforeRemote,
    );
  });

  test('does not inspect a symlinked directory outside the Workstream',
      () async {
    final outside = await Directory.systemTemp.createTemp('conclave-outside-');
    addTearDown(() => outside.delete(recursive: true));
    final repository =
        Directory('${outside.path}${Platform.pathSeparator}repo');
    await repository.create();
    await runGit(repository, ['init', '-q']);
    final link = Link('${workstream.path}${Platform.pathSeparator}outside');
    await link.create(repository.path);

    final repositories =
        await const WorkstreamRepositoryDiscovery().discover(workstream);
    expect(repositories, isEmpty);
  });
}
