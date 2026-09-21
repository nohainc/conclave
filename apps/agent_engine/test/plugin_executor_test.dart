import 'dart:async';
import 'dart:io';

import 'package:conclave_agent_engine/cloud_connection.dart';
import 'package:conclave_agent_engine/plugin_executor.dart';
import 'package:test/test.dart';
import 'fixture_copy.dart';

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
        executable: Platform.resolvedExecutable,
        arguments: ['run', 'bin/echo_plugin.dart'],
        workingDirectory: pluginDirectory.path,
      ),
      {
        'objective': 'inspect repository',
        'pluginId': 'conclave.echo',
      },
    );

    expect(result['status'], 'completed');
    expect(result['summary'], contains('echo worker'));
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
        executable: Platform.resolvedExecutable,
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
  });

  test('terminates a plugin that does not answer before the timeout', () async {
    await expectLater(
      PluginProcessExecutor().execute(
        PluginProcessSpec(
          pluginId: 'silent',
          executable: Platform.resolvedExecutable,
          arguments: ['-e', 'Future<void>.delayed(Duration(seconds: 5));'],
        ),
        {},
        timeout: const Duration(milliseconds: 50),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('cancels an active plugin process by operation ID', () async {
    final executor = PluginProcessExecutor();
    final execution = executor.execute(
      PluginProcessSpec(
        pluginId: 'silent',
        executable: Platform.resolvedExecutable,
        arguments: ['-e', 'Future<void>.delayed(Duration(seconds: 5));'],
      ),
      {},
      operationId: 'assignment-cancel-1',
      timeout: const Duration(seconds: 10),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await executor.cancel('assignment-cancel-1'), isTrue);
    await expectLater(execution, throwsA(isA<ProcessException>()));
  });

  test('executes the Forge plugin against the real fixture repository',
      () async {
    final repository = Directory.current.parent.parent;
    final fixture = await copyForgeFixture();
    try {
      final result = await PluginProcessExecutor().execute(
        PluginProcessSpec(
          pluginId: 'conclave.forge',
          executable: Platform.resolvedExecutable,
          arguments: ['run', 'bin/forge_plugin.dart'],
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
