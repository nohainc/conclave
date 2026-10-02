import 'dart:io';

import 'package:conclave_workspace/workspace.dart';
import 'package:conclave_workspace/workspace_configuration.dart';
import 'package:conclave_workspace/workspace_runtime.dart';
import 'package:test/test.dart';

void main() {
  group('InstallationIdentityStore', () {
    late Directory tempDir;

    setUp(() async {
      tempDir =
          await Directory.systemTemp.createTemp('conclave-install-id-test-');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('generates valid install_<uuidv4> format on first launch', () async {
      final store = InstallationIdentityStore(tempDir);
      expect(store.readSync(), isNull);

      final id = await store.getOrCreate();
      expect(id, startsWith('install_'));

      final uuidPart = id.substring('install_'.length);
      final uuidV4Regex = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(uuidV4Regex.hasMatch(uuidPart), isTrue);
    });

    test('persists to non-secret local state and survives restart', () async {
      final store1 = InstallationIdentityStore(tempDir);
      final id1 = await store1.getOrCreate();

      // Verify file exists on disk
      expect(store1.file.existsSync(), isTrue);
      expect(store1.readSync(), equals(id1));

      // Simulate app restart by creating a new store instance with same dataDirectory
      final store2 = InstallationIdentityStore(tempDir);
      final id2 = await store2.getOrCreate();
      expect(id2, equals(id1));
      expect(store2.readSync(), equals(id1));
    });

    test('survives computer rename, workspace rename, and config changes',
        () async {
      final store = InstallationIdentityStore(tempDir);
      final id = await store.getOrCreate();

      // WorkspaceConfig with initial workspace
      final config1 = WorkspaceConfig(
        dataDirectory: tempDir,
        workspaceRuntimeId: 'runtime-1',
        workspaceId: 'ws-old-name',
      );
      final host1 = await buildWorkspaceRuntime(config1);
      expect(host1.installationId, equals(id));
      await host1.stop();

      // Simulate machine renamed and workspace renamed to "Engineering"
      final config2 = WorkspaceConfig(
        dataDirectory: tempDir,
        workspaceRuntimeId: 'runtime-1',
        workspaceId: 'ws-new-name',
      );
      final host2 = await buildWorkspaceRuntime(config2);
      expect(host2.installationId, equals(id));
      await host2.stop();

      // Reading directly from store still yields the exact same ID
      expect(store.readSync(), equals(id));
    });

    test('WorkspaceConfig.fromArgs reads persisted installation ID', () async {
      final store = InstallationIdentityStore(tempDir);
      final id = await store.getOrCreate();

      final config = WorkspaceConfig.fromArgs([
        '--data-dir',
        tempDir.path,
      ]);
      expect(config.installationId, equals(id));
    });

    test('generates unique IDs across separate installations', () async {
      final tempDir2 =
          await Directory.systemTemp.createTemp('conclave-install-id-test2-');
      addTearDown(() => tempDir2.delete(recursive: true));

      final store1 = InstallationIdentityStore(tempDir);
      final store2 = InstallationIdentityStore(tempDir2);

      final id1 = await store1.getOrCreate();
      final id2 = await store2.getOrCreate();

      expect(id1, isNot(equals(id2)));
    });

    test('clear removes the stored installation ID', () async {
      final store = InstallationIdentityStore(tempDir);
      final id = await store.getOrCreate();
      expect(store.readSync(), equals(id));

      await store.clear();
      expect(store.readSync(), isNull);
    });

    test('explicit recovery authorization survives pairing screen restart',
        () async {
      final store = InstallationIdentityStore(tempDir);
      final installationId = await store.getOrCreate();
      expect(store.recoveryAuthorizedSync(), isFalse);

      await store.authorizeRecovery();
      final restarted = InstallationIdentityStore(tempDir);
      expect(restarted.recoveryAuthorizedSync(), isTrue);
      expect(await restarted.getOrCreate(), installationId);

      await restarted.clearRecoveryAuthorization();
      expect(store.recoveryAuthorizedSync(), isFalse);
    });
  });
}
