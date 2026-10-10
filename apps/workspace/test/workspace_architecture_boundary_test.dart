import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _source(String path) => File(path).readAsStringSync();

void main() {
  test('Workspace UI remains a management client', () {
    final uiParts = [
      _source('lib/main/app.dart'),
      _source('lib/main/management.dart'),
      _source('lib/main/shell.dart'),
      _source('lib/main/dashboard.dart'),
      _source('lib/main/workers.dart'),
    ].join('\n');

    expect(uiParts, isNot(contains('WorkspaceCloudConnection(')));
    expect(uiParts, isNot(contains('CliWorkerEngineSupervisor(')));
    expect(uiParts, isNot(contains('Process.start(')));
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
    expect(engine, isNot(contains('d1')));
    expect(engine, contains('conclave_worker_protocol'));
  });

  test('service stop is separate from host registration', () {
    final serviceManager = _source('lib/workspace_background_service.dart');

    expect(serviceManager, contains('Future<WorkspaceServiceInfo> stop()'));
    expect(
        serviceManager, contains('Future<WorkspaceServiceInfo> unregister()'));
    expect(
      serviceManager.indexOf('stop()'),
      isNot(serviceManager.indexOf('unregister()')),
    );
  });
}
