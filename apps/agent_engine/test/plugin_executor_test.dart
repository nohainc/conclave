import 'dart:io';

import 'package:conclave_agent_engine/cloud_connection.dart';
import 'package:conclave_agent_engine/plugin_executor.dart';
import 'package:test/test.dart';

void main() {
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
}
