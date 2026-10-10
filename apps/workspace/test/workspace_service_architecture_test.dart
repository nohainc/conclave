import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_workspace/secure_credentials.dart';
import 'package:conclave_workspace/workspace.dart';
import 'package:conclave_workspace/workspace_configuration.dart';
import 'package:conclave_workspace/workspace_service_lifecycle.dart';

class _MemoryCredentials implements SecureCredentialStore {
  final values = <String, String>{};

  @override
  String? readSync(String key) => values[key];

  @override
  Future<String?> read(String key) async => readSync(key);

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  test('configuration resolver produces one resolved service configuration',
      () async {
    final root = await Directory.systemTemp.createTemp('workspace-config-');
    addTearDown(() => root.delete(recursive: true));
    final credentials = _MemoryCredentials()
      ..values['runtime-1'] = 'runtime-secret';

    final resolved = const WorkspaceConfigurationResolver().resolve(
      [
        '--data-dir',
        root.path,
        '--cloud-url',
        'https://example.test',
        '--workspace-runtime-id',
        'runtime-1',
        '--workspace-id',
        'workspace-1',
        '--work-root',
        '${root.path}/work',
      ],
      credentialStore: credentials,
    );

    expect(resolved.dataDirectory.path, root.path);
    expect(resolved.workspaceRuntimeId, 'runtime-1');
    expect(resolved.workspaceId, 'workspace-1');
    expect(resolved.credentials.runtimeToken, 'runtime-secret');
    expect(resolved.cloudUri?.scheme, 'wss');
    expect(resolved.cloudUri?.path, '/api/workspace-gateway/connect');
    expect(resolved.workRootPath, '${root.path}/work');
  });

  test('service lifecycle derives independent health and Cloud readiness', () {
    const lifecycle = WorkspaceServiceLifecycle(
      installation: ServiceInstallationState.registered,
      runtime: ServiceRuntimeState.running,
      cloud: CloudConnectionState.disconnected,
      ipcReady: true,
    );

    expect(lifecycle.serviceHealthy, isTrue);
    expect(lifecycle.canManageWorkers, isTrue);
    expect(lifecycle.canConnect, isTrue);
  });
}
