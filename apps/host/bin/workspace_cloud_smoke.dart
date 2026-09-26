import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/host.dart';
import 'package:conclave_host/secure_credentials.dart';
import 'package:conclave_host/workspace_enrollment.dart';
import 'package:conclave_host/workspace_runtime.dart';

class _MemoryCredentialStore implements SecureCredentialStore {
  final Map<String, String> values = {};

  @override
  String? readSync(String key) => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

Future<void> main(List<String> args) async {
  String? option(String name) {
    final index = args.indexOf(name);
    if (index < 0 || index + 1 >= args.length) return null;
    return args[index + 1];
  }

  final cloudUrl = option('--cloud-url');
  final enrollmentToken = option('--enrollment-token');
  if (cloudUrl == null || enrollmentToken == null) {
    stderr.writeln(
      'Usage: dart run bin/workspace_cloud_smoke.dart '
      '--cloud-url <https://...> --enrollment-token <one-time-code>',
    );
    exitCode = 64;
    return;
  }

  final dataDirectory =
      await Directory.systemTemp.createTemp('conclave-workspace-smoke-');
  final credentials = _MemoryCredentialStore();
  Host? runtime;
  try {
    final pairing = WorkspacePairingService(
      dataDirectory: dataDirectory,
      credentialStore: credentials,
    );
    final registration = await pairing.pair(
      cloudUrl: cloudUrl,
      token: enrollmentToken,
      hostname: 'conclave-workspace-smoke',
    );

    final config = HostConfig.fromArgs(
      ['--data-dir', dataDirectory.path],
      credentialStore: credentials,
    );
    runtime = await buildWorkspaceRuntime(config);
    await runtime.start();

    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (runtime.cloudConnection?.isConnected != true &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (runtime.cloudConnection?.isConnected != true) {
      throw StateError(
        'Workspace paired but did not establish the Cloud gateway connection.',
      );
    }

    stdout.writeln(jsonEncode({
      'ok': true,
      'workspaceId': registration.workspaceId,
      'workspaceRuntimeId': registration.hostId,
      'cloudUrl': registration.cloudUrl,
      'connected': true,
    }));
  } finally {
    await runtime?.stop();
    await dataDirectory.delete(recursive: true);
  }
}
