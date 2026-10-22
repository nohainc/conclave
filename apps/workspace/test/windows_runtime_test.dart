import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_workspace/windows_credentials.dart';
import 'package:conclave_workspace/workspace_paths.dart';
import 'package:conclave_workspace/secure_credentials.dart';
import 'package:conclave_workspace/workspace_configuration.dart';
import 'package:conclave_workspace/windows_native.dart';
import 'package:conclave_workspace/workspace_manager_ipc.dart';
import 'package:conclave_workspace/local_management_transport.dart';

void main() {
  test('IPC bounds unterminated input before JSON decoding', () async {
    final stream =
        managementLines(Stream.value(List.filled(1024 * 1024 + 1, 65)));
    await expectLater(stream.toList(), throwsFormatException);
  });
  test('IPC handles fragmented UTF8 and CRLF', () async {
    final bytes = utf8.encode('{"text":"ž"}\r\n');
    expect(
        await managementLines(Stream.fromIterable(bytes.map((b) => [b])))
            .toList(),
        ['{"text":"ž"}']);
  });
  test('Windows legacy state is preserved until its root is selected',
      () async {
    final root = await Directory.systemTemp.createTemp('conclave-legacy-');
    try {
      final legacy = Directory('${root.path}/legacy');
      final target = Directory('${root.path}/new');
      final identity = File('${legacy.path}/installation-id');
      await identity.create(recursive: true);
      await identity.writeAsString('install_original');
      expect(
          () => WorkspacePaths.resolveWindowsStateDirectory(
              legacy: legacy, target: target),
          throwsStateError);
      expect(await identity.readAsString(), 'install_original');
      expect(target.existsSync(), false);
    } finally {
      await root.delete(recursive: true);
    }
  });
  test('Windows cached credentials rotate in the selected private state root',
      () async {
    final root = await Directory.systemTemp.createTemp('conclave-store-');
    try {
      final store = PlatformSecureCredentialStore(
          service: root.path, windowsCredentialDirectory: root);
      await store.write('account', 'initial');
      await store.readForSynchronousConfig('account');
      await store.write('account', 'rotated');
      expect(store.readSync('account'), 'rotated');
      await store.delete('account');
      expect(store.readSync('account'), isNull);
    } finally {
      await root.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
  test('Windows service can acquire and release a process-owned power request',
      () {
    final handle = WindowsNative.acquirePowerRequest();
    WindowsNative.releasePowerRequest(handle);
  }, skip: !Platform.isWindows);
  test('DPAPI persists ciphertext and binds service/account', () async {
    final dir = await Directory.systemTemp.createTemp('conclave-dpapi-');
    try {
      final store = WindowsCredentials(dir);
      const secret = 'runtime-credential-ž-1234';
      store.write('service', 'account', secret);
      final encrypted = await (await dir.list().single as File).readAsBytes();
      expect(utf8.decode(encrypted, allowMalformed: true),
          isNot(contains(secret)));
      expect(WindowsCredentials(dir).read('service', 'account'), secret);
      expect(
          () => WindowsNative.protect(encrypted, 'another-account',
              decrypt: true),
          throwsA(isA<FileSystemException>()));
      store.write('service', 'account', 'rotated');
      expect(store.read('service', 'account'), 'rotated');
      store.delete('service', 'account');
      expect(store.read('service', 'account'), isNull);
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
  test('Windows pipe authenticates, rejects bad keys, and restarts', () async {
    final dir = await Directory.systemTemp.createTemp('conclave-pipe-');
    await InstallationIdentityStore(dir).getOrCreate();
    WorkspaceManagerIpcServer makeServer() => WorkspaceManagerIpcServer(
          runtimeDirectory: Directory('${dir.path}/runtime'),
          serviceVersion: 'windows-test',
          snapshotProvider: () async => {'ready': true},
          requestHandler: (name, payload) async =>
              {'name': name, 'payload': payload},
        );
    var server = makeServer();
    try {
      await server.start();
      final key =
          await File('${dir.path}/runtime/manager-ipc.key').readAsString();
      await expectLater(
          WorkspaceManagerIpcClient.connect(
              socketPath: server.socketPath, key: 'bad-key'),
          throwsA(isA<WorkspaceManagerProtocolException>()));
      final client = await WorkspaceManagerIpcClient.connect(
          socketPath: server.socketPath, key: key);
      expect(client.initialSnapshot['ready'], true);
      expect(await client.request('echo', payload: {'value': 'ž & % ! "'}), {
        'name': 'echo',
        'payload': {'value': 'ž & % ! "'}
      });
      await client.close();
      await server.close();
      server = makeServer();
      await server.start();
      final next = await WorkspaceManagerIpcClient.connect(
          socketPath: server.socketPath, key: key);
      expect(next.serviceVersion, 'windows-test');
      await next.close();
    } finally {
      await server.close();
      await dir.delete(recursive: true);
    }
  }, skip: !Platform.isWindows, timeout: const Timeout(Duration(seconds: 40)));
}
