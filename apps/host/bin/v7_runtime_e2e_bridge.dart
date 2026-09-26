import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/cloud_connection.dart';
import 'package:conclave_host/configured_worker_registry.dart';
import 'package:conclave_host/v7_adapter_package_store.dart';
import 'package:conclave_host/worker_executor.dart';
import 'package:conclave_host/worker_protocol.dart';
import 'package:conclave_host/worker_trust_policy.dart';
import 'package:conclave_host/workstream_directory.dart';
import 'package:conclave_host/workstream_path.dart';

/// Test-only stdio transport for pairing the real Host runtime with Cloud's
/// WorkspaceGateway in an integration test. It never runs in product builds.
class _BridgeSocket implements HostCloudSocket {
  _BridgeSocket(this.messages);
  @override
  final Stream<Object?> messages;

  @override
  void send(Object message) =>
      stdout.writeln(message is String ? message : jsonEncode(message));

  @override
  Future<void> close() async {}
}

String _platform() {
  final os = switch (Platform.operatingSystem) {
    'macos' => 'macos',
    'windows' => 'windows',
    'linux' => 'linux',
    _ => 'linux',
  };
  final hint = '${Platform.version} ${Platform.environment['HOSTTYPE'] ?? ''}'
      .toLowerCase();
  final arch =
      hint.contains('arm64') || hint.contains('aarch64') ? 'arm64' : 'x64';
  return '$os-$arch';
}

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('temporary Workspace data path required');
  }
  final root = Directory(args.single);
  await root.create(recursive: true);
  const workspaceId = 'workspace-v7-e2e';
  const runtimeId = 'runtime-v7-e2e';
  const workerId = 'worker-local-v7-e2e';
  const typeId = 'fixture-worker';
  const fixtureSecret = 'test-only-adapter-signing-secret';
  const allowedPermissions = {
    WorkerPermission.readWorkspace,
    WorkerPermission.writeWorkspace,
  };
  const trust =
      WorkerTrustPolicy(trustedSecrets: {'Conclave Test': fixtureSecret});
  final registry = LocalConfiguredWorkerRegistry(
    dataDirectory: Directory('${root.path}/workspace-data'),
    workspaceId: workspaceId,
    idGenerator: () => workerId,
  );
  final worker = await registry.create(
    name: 'V7 E2E local fixture',
    workerTypeId: typeId,
    authStrategy: 'none',
    defaultModel: 'fixture-model',
    allowedModels: const ['fixture-model'],
    localPermissions: const [
      'repository:read',
      'repository:write',
      'workspace:read',
      'workspace:write',
    ],
    localConcurrencyLimit: 1,
    adapterVersionPolicy: 'stable',
    status: LocalWorkerStatus.ready,
    credentialStatus: LocalWorkerCredentialStatus.notRequired,
  );
  final source = Directory('${root.path}/source');
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
        await File('$cwd/v7-e2e-output.txt').writeAsString('written-by-real-adapter-process');
        stdout.writeln(jsonEncode({...base, 'type': 'progress', 'assignmentId': request['assignmentId'], 'message': 'fixture progress', 'percentage': 50}));
        stdout.writeln(jsonEncode({...base, 'type': 'result', 'assignmentId': request['assignmentId'], 'output': jsonEncode({'cwd': cwd, 'file': await File('$cwd/v7-e2e-output.txt').readAsString()})}));
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
  if (chmod.exitCode != 0) {
    throw StateError('could not mark fixture executable');
  }

  final store = V7AdapterPackageStore(
    root: Directory('${root.path}/installed'),
    trustPolicy: trust,
    allowedPermissions: allowedPermissions,
    platform: _platform(),
  );
  final digest = await store.digestDirectory(source);
  final manifest = <String, Object?>{
    'workerTypeId': typeId,
    'adapterVersion': '1.0.0',
    'protocolVersion': '1.0',
    'publisher': 'Conclave Test',
    'displayName': 'V7 deterministic E2E fixture',
    'supportedPlatforms': [_platform()],
    'capabilities': ['code'],
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

  final incoming = StreamController<Object?>();
  final socket = _BridgeSocket(incoming.stream);
  final workRoot = Directory('${root.path}/work-root')
    ..createSync(recursive: true);
  late final HostCloudConnection connection;
  final handler = WorkerAssignmentHandler(
    executor: WorkerProcessExecutor(),
    resolve: (_) async => null,
    resolveV7Adapter: (id) async {
      final local = await registry.find(id);
      if (local == null || local.status != LocalWorkerStatus.ready) return null;
      return store.resolve(worker: local, readCredential: (_) => null);
    },
    resolvePermissions: (id) async =>
        (await registry.find(id))?.localPermissions.toSet() ?? <String>{},
    resolveConcurrencyLimit: (id) async =>
        (await registry.find(id))?.localConcurrencyLimit,
    workstreamDirectoryLifecycle: WorkstreamDirectoryLifecycle(
      pathResolver: WorkstreamPathResolver(workRoot),
    ),
    onNotification: (context, notification) =>
        connection.reportWorkerNotification(
      context,
      WorkerRpcNotification(
        method: notification.method,
        params: {...notification.params, 'assignmentId': context.assignmentId},
      ),
    ),
  );
  connection = HostCloudConnection(
    uri: Uri.parse('ws://stdio/workspace-gateway'),
    hostId: runtimeId,
    workspaceId: workspaceId,
    factory: (_) async => socket,
    name: 'V7 E2E Workspace',
    heartbeat: const Duration(hours: 1),
    assignmentHandler: handler.call,
    workerInventoryProvider: () async {
      Map<String, Object?>? active;
      try {
        active = await store.activeManifestSummary(worker);
      } on Object catch (error) {
        stderr.writeln('fixture manifest summary unavailable: $error');
      }
      return [
        {
          'workerId': worker.id,
          'workerTypeId': worker.workerTypeId,
          'name': worker.name,
          'status': 'ready',
          'authStrategy': worker.authStrategy,
          'defaultModel': worker.defaultModel,
          'allowedModels': worker.allowedModels,
          'capabilities': active?['capabilities'] ?? const <String>[],
          'localPermissionsSummary': worker.localPermissions,
          'localConcurrencyLimit': worker.localConcurrencyLimit,
          'adapterVersion': active?['adapterVersion'],
          'credentialStatus': 'not_required',
          'revision': worker.revision,
          'createdAt': worker.createdAt,
          'updatedAt': worker.updatedAt,
          'lastSeenAt': DateTime.now().toUtc().toIso8601String(),
        }
      ];
    },
  );
  await connection.connect();
  final inputDone = Completer<void>();
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) async {
    if (line == '{"bridge":"close"}') {
      await connection.close();
      await incoming.close();
      if (!inputDone.isCompleted) inputDone.complete();
    } else {
      incoming.add(line);
    }
  }, onDone: () {
    if (!inputDone.isCompleted) inputDone.complete();
  });
  await inputDone.future;
}
