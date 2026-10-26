import 'dart:io';

import 'package:test/test.dart';

String _source(String path) => File(path).readAsStringSync();

void main() {
  test('Workspace CLI remains an IPC management client', () {
    final cli = _source('lib/workspace_cli.dart');

    expect(cli, isNot(contains('WorkspaceCloudConnection(')));
    expect(cli, isNot(contains('CliWorkerEngineSupervisor(')));
    expect(cli, isNot(contains('buildWorkspaceRuntime(')));
  });

  test('the service owns Cloud and Worker subsystem composition', () {
    final runtime = _source('lib/workspace_runtime.dart');
    final manager = _source('lib/workspace_manager_service.dart');

    expect(runtime, contains('WorkspaceWorkerSubsystem'));
    expect(runtime, contains('WorkspaceCloudConnection'));
    expect(manager, contains('WorkspaceRuntime'));
    expect(manager, contains('WorkspaceManagerIpcServer'));
  });

  test('the generic Worker Engine protocol has no Cloud dependency', () {
    final engine = _source(
      '../../packages/conclave_cli_worker_runtime/lib/src/cli_worker_engine_supervisor.dart',
    );

    expect(engine, isNot(contains('cloud_connection')));
    expect(engine, isNot(contains('workspace_gateway')));
    // Whole-word match: a bare substring would also hit unrelated identifiers.
    expect(engine, isNot(contains(RegExp(r'\bd1\b', caseSensitive: false))));
    expect(engine, contains('conclave_worker_protocol'));
  });

  test('service stop is separate from host registration', () {
    final serviceManager = _source('lib/workspace_background_service.dart');

    // The manager interface exposes stopping and unregistering as two
    // distinct operations, so stopping the Service never implies removing its
    // host registration.
    for (final method in ['stop', 'unregister']) {
      expect(
        RegExp('Future<WorkspaceServiceInfo> $method\\(\\);')
            .allMatches(serviceManager),
        hasLength(1),
        reason: 'the manager interface must declare $method() exactly once',
      );
    }
  });
}
