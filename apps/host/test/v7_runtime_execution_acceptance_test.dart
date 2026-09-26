import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/cloud_connection.dart';
import 'package:conclave_host/configured_worker_registry.dart';
import 'package:conclave_host/runtime_capabilities.dart';
import 'package:conclave_host/v7_adapter_package_store.dart';
import 'package:conclave_host/worker_executor.dart';
import 'package:conclave_host/worker_trust_policy.dart';
import 'package:conclave_host/workstream_directory.dart';
import 'package:conclave_host/workstream_path.dart';
import 'package:test/test.dart';

void main() {
  test(
      'local V7 Worker runs an admitted adapter in its ID-only Workstream directory',
      () async {
    final temp =
        await Directory.systemTemp.createTemp('v7-runtime-acceptance-');
    addTearDown(() => temp.delete(recursive: true));
    const trust =
        WorkerTrustPolicy(trustedSecrets: {'Conclave Test': 'fixture-only'});
    const permissions = {
      WorkerPermission.readWorkspace,
      WorkerPermission.writeWorkspace
    };
    final registry = LocalConfiguredWorkerRegistry(
      dataDirectory: Directory('${temp.path}/workspace-data'),
      workspaceId: 'workspace-owned-by-runtime',
      idGenerator: () => 'worker-local-42',
      clock: () => DateTime.utc(2026, 9, 26),
    );
    final worker = await registry.create(
      name: 'Display name must not become a path',
      workerTypeId: 'test-adapter',
      authStrategy: 'none',
      defaultModel: 'fixture-model',
      allowedModels: const ['fixture-model'],
      localPermissions: const ['workspace:read', 'workspace:write'],
      localConcurrencyLimit: 1,
      adapterVersionPolicy: 'stable',
      status: LocalWorkerStatus.ready,
      credentialStatus: LocalWorkerCredentialStatus.notRequired,
    );

    final source = Directory('${temp.path}/source');
    await Directory('${source.path}/bin').create(recursive: true);
    await File('${source.path}/bin/adapter.dart').writeAsString(r'''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map<String, dynamic>;
    final base = {'protocolVersion': '1.0', 'requestId': request['requestId']};
    switch (request['type']) {
      case 'initialize.request': stdout.writeln(jsonEncode({...base, 'type': 'initialize.result', 'adapterVersion': '1.0.0', 'capabilities': <String>[]}));
      case 'version.request': stdout.writeln(jsonEncode({...base, 'type': 'version.result', 'adapterVersion': '1.0.0'}));
      case 'health.request': stdout.writeln(jsonEncode({...base, 'type': 'health.result', 'healthy': true}));
      case 'validate.request': stdout.writeln(jsonEncode({...base, 'type': 'validate.result', 'ready': true, 'issues': <Object>[]}));
      case 'execute.request':
        final cwd = Directory.current.path;
        await File('${cwd}/fixture.txt').writeAsString('written-by-adapter');
        stdout.writeln(jsonEncode({...base, 'type': 'progress', 'assignmentId': request['assignmentId'], 'message': 'fixture running', 'percentage': 50}));
        stdout.writeln(jsonEncode({...base, 'type': 'result', 'assignmentId': request['assignmentId'], 'output': jsonEncode({'cwd': cwd, 'file': await File('${cwd}/fixture.txt').readAsString()})}));
    }
  }
}
''');
    final launcher = File('${source.path}/bin/adapter');
    await launcher.writeAsString(r'''#!/bin/sh
exec __DART__ "$(dirname "$0")/adapter.dart"
'''
        .replaceFirst('__DART__', Platform.resolvedExecutable));
    final chmod = await Process.run('chmod', ['700', launcher.path]);
    expect(chmod.exitCode, 0);

    final store = V7AdapterPackageStore(
      root: Directory('${temp.path}/installed'),
      trustPolicy: trust,
      allowedPermissions: permissions,
      platform: 'linux-x64',
    );
    final digest = await store.digestDirectory(source);
    final manifest = <String, Object?>{
      'workerTypeId': 'test-adapter',
      'adapterVersion': '1.0.0',
      'protocolVersion': '1.0',
      'publisher': 'Conclave Test',
      'displayName': 'Deterministic test adapter',
      'supportedPlatforms': ['linux-x64'],
      'capabilities': ['fixture'],
      'permissions': ['workspace:read', 'workspace:write'],
      'authStrategies': ['none'],
      'modelSelectionMode': 'allow_list',
      'prerequisites': <Object>[],
      'executable': 'bin/adapter',
      'launchArgs': <String>[],
      'secretRequirements': <Object>[],
      'healthCheck': {'mode': 'protocol', 'timeoutMs': 5000},
      'packageDigest': digest,
      'signature': '',
      'releaseChannel': 'stable',
    };
    manifest['signature'] =
        trust.signAdapterManifest('Conclave Test', digest, manifest);
    await File('${source.path}/manifest.json')
        .writeAsString(jsonEncode(manifest));
    await store.install(sourceDirectory: source);

    final progress = <String>[];
    final workRoot = Directory('${temp.path}/work-root');
    await workRoot.create(recursive: true);
    final handler = WorkerAssignmentHandler(
      executor: WorkerProcessExecutor(),
      resolve: (_) async => null,
      resolveV7Adapter: (workerId) async {
        final local = await registry.find(workerId);
        if (local == null || local.status != LocalWorkerStatus.ready) {
          return null;
        }
        return store.resolve(worker: local, readCredential: (_) => null);
      },
      resolvePermissions: (workerId) async =>
          (await registry.find(workerId))?.localPermissions.toSet() ??
          <String>{},
      resolveConcurrencyLimit: (workerId) async =>
          (await registry.find(workerId))?.localConcurrencyLimit,
      workstreamDirectoryLifecycle: WorkstreamDirectoryLifecycle(
        pathResolver: WorkstreamPathResolver(workRoot),
      ),
      onNotification: (context, notification) {
        if (notification.method == 'worker.progress') {
          progress.add(
              '${notification.params['message']}:${notification.params['percentage']}');
        }
      },
    );
    final context = HostAssignmentContext(
      workspaceId: worker.workspaceId,
      hostId: worker.workspaceId,
      workerId: worker.id,
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'attempt-1',
      assignmentId: 'assignment-1',
      idempotencyKey: 'idempotency-1',
      payload: {
        'workerId': worker.id,
        'workerTypeId': worker.workerTypeId,
        'projectId': 'project-id-1',
        'workstreamId': 'workstream-id-9',
        'executionClass': 'stateless_read',
        'model': 'fixture-model',
        'permissions': ['workspace:read', 'workspace:write'],
      },
    );
    final result = await handler(context);
    final expectedCwd =
        '${await workRoot.resolveSymbolicLinks()}/project-id-1/workstream-id-9';
    expect(worker.id, 'worker-local-42');
    expect(worker.workspaceId, 'workspace-owned-by-runtime');
    expect(progress, ['fixture running:50.0']);
    final output =
        jsonDecode(result.output!['text']! as String) as Map<String, dynamic>;
    expect(output, containsPair('cwd', expectedCwd));
    expect(output, containsPair('file', 'written-by-adapter'));
    expect(await File('$expectedCwd/fixture.txt').readAsString(),
        'written-by-adapter');
    expect(jsonEncode(result.output), isNot(contains('workspace-data')));
    await expectLater(
      handler(context.copyWith(payload: {
        ...context.payload,
        'cwd': temp.path,
      })),
      throwsA(isA<RuntimeViolation>()),
    );
  });
}
