import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_agent_engine/agent_engine.dart';
import 'package:conclave_agent_engine/cloud_connection.dart';
import 'package:conclave_agent_engine/local_ipc.dart';
import 'package:conclave_agent_engine/secure_credentials.dart';
import 'package:test/test.dart';

class FakeSocket implements AgentCloudSocket {
  final controller = StreamController<Object?>();
  final sent = <Object>[];

  @override
  Stream<Object?> get messages => controller.stream;

  @override
  void send(Object message) => sent.add(message);

  @override
  Future<void> close() => controller.close();
}

class FakeCredentialStore implements SecureCredentialStore {
  FakeCredentialStore(this.value);

  final String? value;

  @override
  String? readSync(String key) => value;

  @override
  Future<void> delete(String key) async {}

  @override
  Future<void> write(String key, String value) async {}
}

void main() {
  test('Agent Engine starts, persists state, and stops cleanly', () async {
    final directory = await Directory.systemTemp.createTemp('conclave-engine-');
    final engine =
        AgentEngine(config: AgentEngineConfig(dataDirectory: directory));

    await engine.start();
    expect(engine.isRunning, isTrue);
    expect(File('${directory.path}/engine-state.json').existsSync(), isTrue);
    final ipcFile = File('${directory.path}/ipc.json');
    expect(ipcFile.existsSync(), isTrue);
    expect(engine.ipcPort, isNotNull);

    await engine.stop();
    expect(engine.isRunning, isFalse);
    expect(await File('${directory.path}/engine-state.json').readAsString(),
        contains('stopped'));
    expect(ipcFile.existsSync(), isFalse);
    await directory.delete(recursive: true);
  });

  test('Agent Engine config reads an explicit data directory', () {
    final config =
        AgentEngineConfig.fromArgs(['--data-dir', '/tmp/conclave-agent-test']);
    expect(config.dataDirectory.path, '/tmp/conclave-agent-test');
    expect(Platform.operatingSystem, isNotEmpty);
  });

  test('Agent Engine config reads Cloud enrollment settings', () {
    final config = AgentEngineConfig.fromArgs([
      '--data-dir',
      '/tmp/conclave-agent-test',
      '--cloud-url',
      'wss://cloud.example/agent',
      '--agent-id',
      'agent-1',
      '--workspace-id',
      'workspace-1',
      '--ipc-port',
      '43210',
      '--ipc-token',
      'ipc-secret',
    ]);
    expect(config.cloudUri, Uri.parse('wss://cloud.example/agent'));
    expect(config.agentId, 'agent-1');
    expect(config.workspaceId, 'workspace-1');
    expect(config.ipcPort, 43210);
    expect(config.ipcToken, 'ipc-secret');
  });

  test('Agent Engine resolves an auth token from the secure credential store',
      () {
    final config = AgentEngineConfig.fromArgs(
      ['--agent-id', 'agent-1'],
      credentialStore: FakeCredentialStore('keychain-token'),
    );
    expect(config.authToken, 'keychain-token');
  });

  test('owns the Cloud connection across Engine lifecycle', () async {
    final directory = await Directory.systemTemp.createTemp('conclave-engine-');
    final socket = FakeSocket();
    final connection = AgentCloudConnection(
      uri: Uri.parse('wss://cloud.test/agent'),
      agentId: 'agent-1',
      workspaceId: 'workspace-1',
      factory: (_) async => socket,
    );
    final engine = AgentEngine(
      config: AgentEngineConfig(dataDirectory: directory),
      cloudConnection: connection,
    );

    await engine.start();
    final hello = jsonDecode(socket.sent.single as String) as Map;
    expect(hello['type'], 'agent.hello');
    await engine.stop();
    expect(engine.isRunning, isFalse);
    await directory.delete(recursive: true);
  });

  test('IPC status includes values supplied by the Engine status provider',
      () async {
    final directory = await Directory.systemTemp.createTemp('conclave-engine-');
    final engine = AgentEngine(
      config: AgentEngineConfig(dataDirectory: directory),
      statusProvider: () async => {
        'plugins': 2,
        'pluginIds': ['conclave.codex', 'conclave.forge'],
      },
    );
    await engine.start();
    final metadata = jsonDecode(
      await File('${directory.path}/ipc.json').readAsString(),
    ) as Map<String, dynamic>;
    final client = await LocalIpcClient.connect(
      port: metadata['port'] as int,
      token: metadata['token'] as String,
    );
    final status = await client.command('engine.status', const {});
    expect(status['plugins'], 2);
    expect(status['pluginIds'], ['conclave.codex', 'conclave.forge']);
    await client.close();
    await engine.stop();
    await directory.delete(recursive: true);
  });

  test('restricts IPC metadata to the current user on POSIX', () async {
    if (Platform.isWindows) return;
    final directory = await Directory.systemTemp.createTemp('conclave-engine-');
    final engine = AgentEngine(
      config: AgentEngineConfig(
        dataDirectory: directory,
        ipcToken: 'ipc-secret',
      ),
    );
    await engine.start();
    try {
      final metadata = File('${directory.path}/ipc.json');
      expect((await metadata.stat()).mode & 0x1ff, 0x180); // 0600
      expect((await directory.stat()).mode & 0x1ff, 0x1c0); // 0700
    } finally {
      await engine.stop();
      await directory.delete(recursive: true);
    }
  });
}
