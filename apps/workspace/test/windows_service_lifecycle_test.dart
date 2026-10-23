import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_workspace/workspace_manager_ipc.dart';

void main() {
  test(
      'Windows compiled service IPC, duplicate lock, disconnect and restart preserve identity',
      () async {
    final executable = Platform.environment['CONCLAVE_TEST_WINDOWS_SERVICE'];
    if (executable == null) {
      markTestSkipped(
          'Set CONCLAVE_TEST_WINDOWS_SERVICE to the compiled Windows service');
      return;
    }
    final root = await Directory.systemTemp.createTemp('conclave-lifecycle-');
    final data = Directory('${root.path}/state');
    final work = Directory('${root.path}/work');
    Process? service;
    WorkspaceManagerIpcClient? client;
    final diagnostics = StringBuffer();
    Future<void> start() async {
      service = await Process.start(
          executable, ['--data-dir', data.path, '--work-root', work.path]);
      unawaited(
          service!.stdout.transform(utf8.decoder).forEach(diagnostics.write));
      unawaited(
          service!.stderr.transform(utf8.decoder).forEach(diagnostics.write));
      final until = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(until)) {
        try {
          final runtime = Directory('${data.path}/runtime');
          final key =
              await File('${runtime.path}/manager-ipc.key').readAsString();
          client = await WorkspaceManagerIpcClient.connect(
              socketPath: workspaceManagerEndpoint(runtime), key: key);
          return;
        } on Object {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
      throw StateError('Service IPC did not become ready: $diagnostics');
    }

    Future<void> stop() async {
      await File('${data.path}/runtime/stop-request')
          .writeAsString('stop', flush: true);
      expect(await service!.exitCode.timeout(const Duration(seconds: 15)), 0,
          reason: diagnostics.toString());
      await client?.close();
      client = null;
      service = null;
    }

    try {
      await start();
      expect(
          (client!.initialSnapshot['service'] as Map)['processState'], 'ready',
          reason: diagnostics.toString());
      final identity =
          await File('${data.path}/installation-id').readAsString();
      await client!.request('connection.disconnect');
      expect(await client!.request('service.getHealth'),
          containsPair('healthy', true));
      final duplicate = await Process.run(executable, [
        '--once',
        '--data-dir',
        data.path,
        '--work-root',
        work.path
      ]).timeout(const Duration(seconds: 15));
      expect(duplicate.exitCode, isNot(0));
      expect(await client!.request('service.getHealth'),
          containsPair('healthy', true));
      await stop();
      await start();
      expect(
          await File('${data.path}/installation-id').readAsString(), identity);
      await stop();
    } finally {
      await client?.close();
      if (service != null) {
        service!.kill(ProcessSignal.sigkill);
        await service!.exitCode;
      }
      await root.delete(recursive: true);
    }
  }, skip: !Platform.isWindows, timeout: const Timeout(Duration(seconds: 90)));
}
