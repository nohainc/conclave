import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/cloud_connection.dart';
import 'package:conclave_host/workspace_transport.dart';
import 'package:cryptography/cryptography.dart';
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
  if (args.isEmpty || args.length > 5) {
    throw ArgumentError(
        'temporary Workspace data path and optional transport settings required');
  }
  final root = Directory(args.first);
  final forceFallback = args.length > 1 && args[1] != 'websocket';
  final probeFallback = args.length > 1 && args[1] == 'http_long_poll_handover';
  final fallbackBaseUri = args.length > 2 ? Uri.parse(args[2]) : null;
  final runtimeCredential = args.length > 3 ? args[3] : '';
  final firstPartyAdapter =
      args.length > 4 && args[4].isNotEmpty ? args[4] : null;
  if (firstPartyAdapter != null &&
      !const {'codex', 'antigravity'}.contains(firstPartyAdapter)) {
    throw ArgumentError('unknown first-party adapter fixture');
  }
  await root.create(recursive: true);
  const workspaceId = 'workspace-v7-e2e';
  const runtimeId = 'runtime-v7-e2e';
  const workerId = 'worker-local-v7-e2e';
  final typeId = switch (firstPartyAdapter) {
    'codex' => 'chatgpt',
    'antigravity' => 'gemini',
    _ => 'fixture-worker',
  };
  final adapterTypeId = firstPartyAdapter ?? typeId;
  const modelId = 'fixture-model';
  const signingSeed = <int>[
    0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
    16,
    17,
    18,
    19,
    20,
    21,
    22,
    23,
    24,
    25,
    26,
    27,
    28,
    29,
    30,
    31,
  ];
  const allowedPermissions = {
    WorkerPermission.readWorkspace,
    WorkerPermission.writeWorkspace,
    WorkerPermission.shell,
  };
  final signer = await Ed25519().newKeyPairFromSeed(signingSeed);
  final publicKey = await signer.extractPublicKey();
  final trust = WorkerTrustPolicy(trustedPublicKeys: {
    'Conclave Test': {'test-ed25519-v1': base64.encode(publicKey.bytes)},
  });
  final registry = LocalConfiguredWorkerRegistry(
    dataDirectory: Directory('${root.path}/workspace-data'),
    workspaceId: workspaceId,
    idGenerator: () => workerId,
  );
  final worker = await registry.create(
    name: firstPartyAdapter == null ? 'V7 E2E local fixture' : typeId,
    workerTypeId: typeId,
    authStrategy: firstPartyAdapter == null ? 'none' : 'browser_auth',
    defaultModel: modelId,
    allowedModels: const [modelId],
    localPermissions: [
      'repository:read',
      'repository:write',
      'workspace:read',
      'workspace:write',
      if (firstPartyAdapter != null) 'shell:execute',
    ],
    localConcurrencyLimit: 1,
    adapterVersionPolicy: 'stable',
    status: LocalWorkerStatus.ready,
    credentialStatus: LocalWorkerCredentialStatus.notRequired,
    executablePath: firstPartyAdapter == null
        ? null
        : '${root.path}${Platform.pathSeparator}source${Platform.pathSeparator}bin${Platform.pathSeparator}${firstPartyAdapter == 'codex' ? 'codex' : 'agy'}',
    cliVersion: firstPartyAdapter == 'codex'
        ? '1.2.3'
        : firstPartyAdapter == 'antigravity'
            ? '4.5.6'
            : null,
  );
  final source = Directory('${root.path}/source');
  await Directory('${source.path}/bin').create(recursive: true);
  var adapterExecutable = 'bin/adapter';
  if (firstPartyAdapter == null) {
    await File('${source.path}/bin/adapter.dart').writeAsString(r'''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map<String, dynamic>;
    final base = {'protocolVersion': '2.1', 'requestId': request['requestId']};
    switch (request['type']) {
      case 'initialize.request': stdout.writeln(jsonEncode({...base, 'type': 'initialize.result', 'adapterVersion': '1.0.0', 'capabilities': <String>[]}));
      case 'probe.request': stdout.writeln(jsonEncode({...base, 'type': 'probe.result', 'ready': true, 'toolVersion': null, 'checkKind': 'readiness', 'issues': <Object>[]}));
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
  } else {
    final repositoryRoot =
        File(Platform.script.toFilePath()).parent.parent.parent.parent;
    final adapterFileName = firstPartyAdapter == 'codex'
        ? 'conclave-codex-adapter.mjs'
        : 'conclave-antigravity-adapter.mjs';
    final adapterSource = File(
      '${repositoryRoot.path}${Platform.pathSeparator}packages${Platform.pathSeparator}worker-manifest${Platform.pathSeparator}adapters${Platform.pathSeparator}$firstPartyAdapter${Platform.pathSeparator}bin${Platform.pathSeparator}$adapterFileName',
    );
    await adapterSource.copy('${source.path}/bin/$adapterFileName');
    adapterExecutable = 'bin/$adapterFileName';
    final cliName = firstPartyAdapter == 'codex' ? 'codex' : 'agy';
    final fakeCli = File('${source.path}/bin/$cliName');
    await fakeCli.writeAsString(firstPartyAdapter == 'codex'
        ? r'''#!/bin/sh
if [ "$1" = "--version" ]; then echo 'codex 1.2.3'; exit 0; fi
if [ "$1" = "login" ] && [ "$2" = "status" ]; then echo 'Logged in'; exit 0; fi
cat >/dev/null
printf '%s\n' 'fake Codex execution' > "$PWD/first-party-cli.txt"
printf '%s\n' '{"type":"turn.started"}'
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"fake Codex execution completed"}}'
printf '%s\n' '{"type":"turn.completed"}'
'''
        : r'''#!/bin/sh
if [ "$1" = "--version" ]; then echo 'agy 4.5.6'; exit 0; fi
cat >/dev/null
printf '%s\n' 'fake Antigravity execution' > "$PWD/first-party-cli.txt"
printf '%s\n' '{"event":"init","conversation_id":"fixture","init":{"cwd":"."}}'
printf '%s\n' '{"event":"step_update","step_update":{"state":"RUNNING"}}'
printf '%s\n' '{"event":"result","result":{"status":"SUCCESS","response":"fake Antigravity execution completed"}}'
''');
    final chmod = await Process.run('chmod', ['700', fakeCli.path]);
    if (chmod.exitCode != 0) {
      throw StateError('could not mark fake provider CLI executable');
    }
    final chmodAdapter = await Process.run(
        'chmod', ['700', '${source.path}/$adapterExecutable']);
    if (chmodAdapter.exitCode != 0) {
      throw StateError('could not mark first-party adapter executable');
    }
  }

  final store = V7AdapterPackageStore(
    root: Directory('${root.path}/installed'),
    trustPolicy: trust,
    allowedPermissions: allowedPermissions,
    platform: _platform(),
  );
  final digest = await store.digestDirectory(source);
  final adapterPermissions = firstPartyAdapter == null
      ? ['workspace:read', 'workspace:write']
      : ['workspace:read', 'workspace:write', 'shell:execute'];
  final manifest = <String, Object?>{
    'workerTypeId': adapterTypeId,
    'adapterVersion': '1.0.0',
    'protocolVersion': '2.1',
    'publisher': 'Conclave Test',
    'displayName': firstPartyAdapter == null
        ? 'V7 deterministic E2E fixture'
        : firstPartyAdapter == 'codex'
            ? 'Codex fake CLI E2E fixture'
            : 'Antigravity fake CLI E2E fixture',
    'supportedPlatforms': [_platform()],
    'capabilities':
        firstPartyAdapter == null ? ['code'] : ['code', 'repository', 'shell'],
    'permissions': adapterPermissions,
    'authStrategies': [firstPartyAdapter == null ? 'none' : 'browser_auth'],
    'modelSelectionMode': 'allow_list',
    'prerequisites': <Object>[],
    'executable': adapterExecutable,
    'launchArgs': <String>[],
    'secretRequirements': <Object>[],
    'healthCheck': {'mode': 'protocol', 'timeoutMs': 5000},
    'packageDigest': digest,
    'signingKeyId': 'test-ed25519-v1',
    'signature': '',
    'releaseChannel': 'stable',
  };
  final unsigned = Map<String, Object?>.from(manifest)..remove('signature');
  final signature = await Ed25519().sign(
    utf8.encode(
      'conclave-v7-adapter-release-v1\n$digest\n${canonicalJson(unsigned)}',
    ),
    keyPair: signer,
  );
  manifest['signature'] = base64.encode(signature.bytes);
  await File('${source.path}/manifest.json')
      .writeAsString(jsonEncode(manifest));
  await store.install(sourceDirectory: source);

  final incoming = StreamController<Object?>();
  final socket = _BridgeSocket(incoming.stream);
  var webSocketAttempts = 0;
  final workRoot = Directory('${root.path}/work-root')
    ..createSync(recursive: true);
  late final HostCloudConnection connection;
  final handler = WorkerAssignmentHandler(
    executor: WorkerProcessExecutor(),
    resolve: (_) async => null,
    resolveV7Adapter: (id, {expectedWorkerTypeId}) async {
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
    uri: Uri.parse(
      'ws://stdio/api/workspace-gateway/connect?workspaceRuntimeId=$runtimeId',
    ),
    hostId: runtimeId,
    workspaceId: workspaceId,
    factory: (_) async {
      webSocketAttempts++;
      if (forceFallback && (!probeFallback || webSocketAttempts <= 2)) {
        throw const SocketException('WSS intentionally disabled by acceptance');
      }
      return socket;
    },
    fallbackFactory: forceFallback
        ? (_) => HttpLongPollWorkspaceTransport.connect(
              baseUri: fallbackBaseUri!,
              workspaceRuntimeId: runtimeId,
              runtimeCredential: runtimeCredential,
              pollWait: const Duration(seconds: 1),
            )
        : null,
    webSocketFailureLimit: 2,
    webSocketProbeInterval: probeFallback
        ? const Duration(milliseconds: 1500)
        : const Duration(minutes: 5),
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
  final transportStatusTimer = probeFallback
      ? Timer.periodic(
          const Duration(milliseconds: 50),
          (_) => stdout.writeln('@transport=${connection.activeTransportMode}'),
        )
      : null;
  final inputDone = Completer<void>();
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) async {
    if (line == '{"bridge":"close"}') {
      transportStatusTimer?.cancel();
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
