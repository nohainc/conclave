import 'dart:io';
import 'package:conclave_host/runtime_capabilities.dart';
import 'package:test/test.dart';

void main() {
  Map<String, Object?> scopedPayload({
    String scope = 'selected_paths',
    List<Object?>? pathMappings,
    List<String> permissions = const ['repository:read'],
    Map<String, Object?>? input,
    Map<String, Object?>? networkPolicy,
  }) =>
      {
        'projectId': 'project-1',
        'executionWorkspaceId': 'workspace-1',
        'permissionSnapshot': {
          'projectId': 'project-1',
          'workspaceId': 'workspace-1',
          'grantId': 'grant-1',
          'requesterUserId': 'user-1',
          'scope': scope,
          'permissions': permissions,
          'pathMappings': pathMappings ??
              [
                {
                  'projectPath': '/repo',
                  'workspacePath': '/work/repo',
                }
              ],
          'networkPolicy': networkPolicy ?? {'mode': 'deny_all'},
        },
        'input': input ?? <String, Object?>{},
      };

  test('rejects alternate working directories and traversal mappings', () {
    expect(
      () => validateAssignmentScope(
        scopedPayload(input: {'workingDirectory': '/etc'}),
        manifestPermissions: {'workspace:read'},
      ),
      throwsA(isA<RuntimeViolation>()),
    );
    expect(
      () => validateAssignmentScope(
        scopedPayload(pathMappings: [
          {'projectPath': '../outside', 'workspacePath': '/work/repo'}
        ]),
        manifestPermissions: {'workspace:read'},
      ),
      throwsA(isA<RuntimeViolation>()),
    );
  });

  test('rejects undeclared network and credential material', () {
    expect(
      () => validateAssignmentScope(
        scopedPayload(
          permissions: const ['network:use'],
          networkPolicy: {'mode': 'deny_all'},
        ),
        manifestPermissions: {'network:outbound'},
      ),
      throwsA(isA<RuntimeViolation>()),
    );
    expect(
      () => validateAssignmentScope(
        scopedPayload(input: {'apiKey': 'should-never-cross-runtime'}),
        manifestPermissions: {'workspace:read'},
      ),
      throwsA(isA<RuntimeViolation>()),
    );
  });

  test('permits a validated full Workspace grant on declared permissions', () {
    expect(
      () => validateAssignmentScope(
        scopedPayload(
          scope: 'full_workspace',
          pathMappings: const [],
          permissions: const ['repository:read', 'shell:execute'],
        ),
        manifestPermissions: {'workspace:read', 'shell'},
      ),
      returnsNormally,
    );
  });

  test('rejects system administration even when a manifest declares it', () {
    expect(
      () => validateAssignmentScope(
        scopedPayload(
          scope: 'full_workspace',
          pathMappings: const [],
          permissions: const ['system:admin'],
        ),
        manifestPermissions: const {'system:admin'},
      ),
      throwsA(isA<RuntimeViolation>()),
    );
  });

  test('blocks traversal and permits contained files', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-runtime-');
    final workspace = SafeWorkspace(directory);
    await workspace.write('src/main.txt', 'hello');
    expect(await workspace.read('src/main.txt'), 'hello');
    expect(() => workspace.read('../secret'), throwsA(isA<RuntimeViolation>()));
    await directory.delete(recursive: true);
  });

  test('blocks symlink escapes for reads and writes', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-runtime-');
    final outside =
        await Directory.systemTemp.createTemp('conclave-runtime-outside-');
    final secret = File('${outside.path}/secret.txt')
      ..writeAsStringSync('private');
    await Link('${directory.path}/linked.txt').create(secret.path);
    final workspace = SafeWorkspace(directory);
    await expectLater(
        workspace.read('linked.txt'), throwsA(isA<RuntimeViolation>()));
    await expectLater(workspace.write('linked.txt', 'overwrite'),
        throwsA(isA<RuntimeViolation>()));
    await directory.delete(recursive: true);
    await outside.delete(recursive: true);
  });

  test('blocks writes through broken symlinks before target creation',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-runtime-');
    final outside =
        await Directory.systemTemp.createTemp('conclave-runtime-outside-');
    final missingTarget = '${outside.path}/not-created.txt';
    await Link('${directory.path}/broken.txt').create(missingTarget);
    final workspace = SafeWorkspace(directory);

    await expectLater(
      workspace.write('broken.txt', 'must not escape'),
      throwsA(isA<RuntimeViolation>()),
    );
    expect(await File(missingTarget).exists(), isFalse);

    await directory.delete(recursive: true);
    await outside.delete(recursive: true);
  });

  test('patches exact content and searches bounded text files', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-runtime-');
    final workspace = SafeWorkspace(directory);
    await workspace.write('lib/main.dart', 'return 1;\n');
    await workspace.write('node_modules/ignored.txt', 'return 1;\n');
    await workspace.patch('lib/main.dart', 'return 1;', 'return 2;');
    expect(await workspace.read('lib/main.dart'), 'return 2;\n');
    expect(await workspace.search('return'), ['lib/main.dart']);
    await expectLater(
      workspace.patch('lib/main.dart', 'missing', 'replacement'),
      throwsA(isA<RuntimeViolation>()),
    );
    await directory.delete(recursive: true);
  });

  test('rejects an invalid Git repository', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-runtime-');
    await expectLater(
      GitRepository(SafeWorkspace(directory)).validate(),
      throwsA(isA<RuntimeViolation>()),
    );
    await directory.delete(recursive: true);
  });

  test('creates and removes contained Git worktrees', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-runtime-git-');
    Future<void> runGit(List<String> arguments) async {
      final result =
          await Process.run('git', arguments, workingDirectory: directory.path);
      if (result.exitCode != 0) {
        throw StateError('${result.stdout}\n${result.stderr}');
      }
    }

    await runGit(['init', '-q']);
    await runGit(['config', 'user.email', 'test@example.com']);
    await runGit(['config', 'user.name', 'Conclave Test']);
    await File('${directory.path}/README.md').writeAsString('fixture\n');
    await runGit(['add', 'README.md']);
    await runGit(['commit', '-qm', 'initial']);

    final repository = GitRepository(SafeWorkspace(directory));
    await repository.createWorktree('worktrees/candidate', revision: 'HEAD');
    expect(
      await File('${directory.path}/worktrees/candidate/README.md').exists(),
      isTrue,
    );
    await repository.removeWorktree('worktrees/candidate');
    expect(
      await Directory('${directory.path}/worktrees/candidate').exists(),
      isFalse,
    );
    await expectLater(
      repository.createWorktree('../outside'),
      throwsA(isA<RuntimeViolation>()),
    );
    await directory.delete(recursive: true);
  });

  test('enforces command allowlist and output policy', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-runtime-');
    final runner = SafeCommandRunner(SafeWorkspace(directory));
    final result = await runner.run(['printf', 'hello'],
        policy: const CommandPolicy(allowedExecutables: {'printf'}));
    expect(result.exitCode, 0);
    expect(result.stdout, 'hello');
    expect(
        () => runner.run(['sh', '-c', 'echo unsafe'],
            policy: const CommandPolicy(allowedExecutables: {'printf'})),
        throwsA(isA<RuntimeViolation>()));
    expect(
        () => runner.run(['printf', 'safe; echo unsafe'],
            policy: const CommandPolicy(allowedExecutables: {'printf'})),
        throwsA(isA<RuntimeViolation>()));
    expect(
        () => runner.run(['printf', 'anything'],
            policy: CommandPolicy(
              allowedExecutables: {'printf'},
              allowedArgumentPatterns: {
                'printf': [RegExp(r'^safe$')],
              },
            )),
        throwsA(isA<RuntimeViolation>()));
    await directory.delete(recursive: true);
  });

  test('terminates a command that exceeds the output limit', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-runtime-');
    final runner = SafeCommandRunner(SafeWorkspace(directory));
    final result = await runner.run(
      ['yes'],
      policy: const CommandPolicy(
        allowedExecutables: {'yes'},
        maxOutputBytes: 32,
        timeout: Duration(seconds: 5),
      ),
    );
    expect(result.stdout.length, lessThanOrEqualTo(32));
    await directory.delete(recursive: true);
  });

  test('redacts configured secrets from command evidence', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-runtime-');
    final runner = SafeCommandRunner(SafeWorkspace(directory));
    final result = await runner.run(
      ['printf', 'token-123'],
      policy: const CommandPolicy(
        allowedExecutables: {'printf'},
        secretValues: {'token-123'},
      ),
    );
    expect(result.stdout, '[REDACTED]');
    await directory.delete(recursive: true);
  });

  test('produces stable artifact hashes', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-runtime-');
    final file = File('${directory.path}/artifact.txt')
      ..writeAsStringSync('same');
    final artifact = await stageArtifact(file);
    expect(artifact.sizeBytes, 4);
    expect(artifact.sha256,
        '0967115f2813a3541eaef77de9d9d5773f1c0c04314b0bbfe4ff3b3b1c55b5d5');
    await directory.delete(recursive: true);
  });

  test('rejects artifacts larger than the staging limit', () async {
    final directory =
        await Directory.systemTemp.createTemp('conclave-runtime-');
    final file = File('${directory.path}/large.bin')
      ..writeAsBytesSync(List.filled(16, 1));
    await expectLater(
      stageArtifact(file, maxBytes: 8),
      throwsA(isA<RuntimeViolation>()),
    );
    await directory.delete(recursive: true);
  });
}
