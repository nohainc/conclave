import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_agent_engine/cloud_connection.dart';
import 'package:conclave_agent_engine/plugin_executor.dart';
import 'package:conclave_agent_engine/repository_registry.dart';
import 'package:test/test.dart';
import 'fixture_copy.dart';

Future<Directory> createSilentPlugin() async {
  final directory = await Directory.systemTemp.createTemp('silent-plugin-');
  await File('${directory.path}/silent.dart').writeAsString('''
Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 5));
}
''');
  return directory;
}

void main() {
  test('does not inherit unrelated Agent secrets into plugin processes', () {
    final environment = safePluginEnvironment(
      {'PLUGIN_MODE': 'test'},
      allowedNames: {'PLUGIN_MODE'},
    );

    expect(environment['PLUGIN_MODE'], 'test');
    expect(
        environment.keys.where((key) => key.startsWith('CONCLAVE_')), isEmpty);
    expect(
        safePluginEnvironment({
          'PLUGIN_SECRET': 'must-not-leak-without-explicit-grant',
        })['PLUGIN_SECRET'],
        isNull);
    expect(
        safePluginEnvironment(
          {'PLUGIN_SECRET': 'allowed'},
          allowedNames: {'PLUGIN_SECRET'},
        )['PLUGIN_SECRET'],
        'allowed');
  });

  test('executes a real Worker Plugin through JSON-RPC', () async {
    final repository = Directory.current.parent.parent;
    final pluginDirectory = Directory(
      '${repository.path}/worker_plugins/echo',
    );
    final result = await PluginProcessExecutor().execute(
      PluginProcessSpec(
        pluginId: 'conclave.echo',
        executable: 'dart',
        arguments: ['run', 'bin/echo_plugin.dart'],
        workingDirectory: pluginDirectory.path,
        secretValues: {'sensitive-token'},
      ),
      {
        'objective': 'inspect repository',
        'pluginId': 'conclave.echo',
        'secret': 'sensitive-token',
      },
      timeout: const Duration(seconds: 5),
    );

    expect(result['status'], 'completed');
    expect(result['summary'], contains('echo worker'));
    expect((result['input'] as Map)['secret'], '[REDACTED]');
  });

  test('resolves a plugin into an Agent assignment result', () async {
    final repository = Directory.current.parent.parent;
    final pluginDirectory = Directory(
      '${repository.path}/worker_plugins/echo',
    );
    final handler = PluginAssignmentHandler(
      executor: PluginProcessExecutor(),
      resolve: (_) => PluginProcessSpec(
        pluginId: 'conclave.echo',
        executable: 'dart',
        arguments: ['run', 'bin/echo_plugin.dart'],
        workingDirectory: pluginDirectory.path,
      ),
    );
    final result = await handler.call(const AgentAssignmentContext(
      workspaceId: 'workspace-1',
      agentId: 'agent-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-1',
      idempotencyKey: 'idem-1',
      payload: {'pluginId': 'conclave.echo'},
    ));
    expect(result.summary, contains('echo worker'));
    expect((result.output?['input'] as Map)['conclave']['assignmentId'],
        'assignment-1');
  });

  test('resolves repository IDs through the local registry', () async {
    final repository = await Directory.systemTemp.createTemp('repo-registry-');
    final registryFile = File('${repository.path}/repositories.json')
      ..writeAsStringSync(jsonEncode({'repo-1': repository.path}));
    final registry = await LocalRepositoryRegistry.load(registryFile);
    final handler = PluginAssignmentHandler(
      executor: PluginProcessExecutor(),
      resolve: (_) => PluginProcessSpec(
        pluginId: 'conclave.echo',
        executable: 'dart',
        arguments: ['run', 'bin/echo_plugin.dart'],
        workingDirectory:
            '${Directory.current.parent.parent.path}/worker_plugins/echo',
      ),
      resolveRepositoryPath: registry.resolve,
    );
    final result = await handler.call(const AgentAssignmentContext(
      workspaceId: 'workspace-1',
      agentId: 'agent-1',
      workerId: 'worker-1',
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-repo-1',
      idempotencyKey: 'idem-repo-1',
      payload: {
        'pluginId': 'conclave.echo',
        'repositoryId': 'repo-1',
        'input': <String, Object?>{},
      },
    ));
    expect((result.output?['input'] as Map)['repositoryPath'],
        await repository.resolveSymbolicLinks());
    await repository.delete(recursive: true);
  });

  test('terminates a plugin that does not answer before the timeout', () async {
    final directory = await createSilentPlugin();
    try {
      await expectLater(
        PluginProcessExecutor().execute(
          PluginProcessSpec(
            pluginId: 'silent',
            executable: 'dart',
            arguments: ['run', '${directory.path}/silent.dart'],
          ),
          {},
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<TimeoutException>()),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('cancels an active plugin process by operation ID', () async {
    final directory = await createSilentPlugin();
    final executor = PluginProcessExecutor();
    try {
      final execution = executor.execute(
        PluginProcessSpec(
          pluginId: 'silent',
          executable: 'dart',
          arguments: ['run', '${directory.path}/silent.dart'],
        ),
        {},
        operationId: 'assignment-cancel-1',
        timeout: const Duration(seconds: 10),
      );
      final cancellationExpectation =
          expectLater(execution, throwsA(isA<ProcessException>()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await executor.cancel('assignment-cancel-1'), isTrue);
      await cancellationExpectation;
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('executes the Forge plugin against the real fixture repository',
      () async {
    final repository = Directory.current.parent.parent;
    final fixture = await copyForgeFixture();
    try {
      final result = await PluginProcessExecutor().execute(
        PluginProcessSpec(
          pluginId: 'conclave.forge',
          executable: 'dart',
          arguments: ['--disable-analytics', 'run', 'bin/forge_plugin.dart'],
          workingDirectory: '${repository.path}/worker_plugins/forge',
        ),
        {
          'objective': 'Fix add and verify the implementation',
          'pluginId': 'conclave.forge',
          'input': {'repositoryPath': fixture.path},
        },
        timeout: const Duration(minutes: 1),
      );
      expect(result['status'], 'completed');
      expect(result['summary'], contains('Forge completed'));
    } finally {
      await fixture.parent.delete(recursive: true);
    }
  });
}
