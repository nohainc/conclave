import 'dart:io';

import 'package:conclave_host/worker_configuration.dart';
import 'package:test/test.dart';

Map<String, Object?> worker({
  String workspaceId = 'workspace-1',
  String hostId = 'host-1',
  bool enabled = true,
}) =>
    {
      'workerId': 'worker-1',
      'workspaceId': workspaceId,
      'hostId': hostId,
      'pluginId': 'conclave.codex',
      'pluginVersionPolicy': 'stable',
      'name': 'Codex Main',
      'roles': ['implementation'],
      'capabilities': ['code_edit'],
      'config': <String, Object?>{},
      'secretRefs': <String>[],
      'enabled': enabled,
      'availability': 'available',
      'billingMode': 'subscription',
      'costMetadata': <String, Object?>{},
      'independenceKey': 'host-1:codex',
      'concurrencyLimit': 1,
      'sessionPolicy': 'isolated_workspace',
    };

void main() {
  test('reconciles and persists enabled Worker configuration atomically',
      () async {
    final root = await Directory.systemTemp.createTemp('conclave-workers-');
    final store = WorkerConfigurationStore(
      root,
      workspaceId: 'workspace-1',
      hostId: 'host-1',
    );
    expect(await store.reconcile([worker()]), ['worker-1']);
    expect((await store.read()).single['pluginId'], 'conclave.codex');
    await root.delete(recursive: true);
  });

  test('rejects a Worker from another workspace or Host', () async {
    final root = await Directory.systemTemp.createTemp('conclave-workers-');
    final store = WorkerConfigurationStore(
      root,
      workspaceId: 'workspace-1',
      hostId: 'host-1',
    );
    await expectLater(
      store.reconcile([worker(workspaceId: 'workspace-2')]),
      throwsA(isA<StateError>()),
    );
    await root.delete(recursive: true);
  });

  test('does not advertise disabled Workers as active', () async {
    final root = await Directory.systemTemp.createTemp('conclave-workers-');
    final store = WorkerConfigurationStore(
      root,
      workspaceId: 'workspace-1',
      hostId: 'host-1',
    );
    expect(await store.reconcile([worker(enabled: false)]), isEmpty);
    await root.delete(recursive: true);
  });
}
