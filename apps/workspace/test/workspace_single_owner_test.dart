import 'dart:io';

import 'package:conclave_workspace/workspace.dart';
import 'package:test/test.dart';

void main() {
  test('installation lock prevents two runtime owners from starting', () async {
    final directory =
        await Directory.systemTemp.createTemp('workspace-single-owner-');
    final config = WorkspaceConfig(
      dataDirectory: directory,
      installationId: 'install-stable',
      workRootPath: '${directory.path}/work',
    );
    final serviceOwner = Workspace(config: config);
    try {
      await serviceOwner.start();
      final child = await Process.start(
        Platform.resolvedExecutable,
        [
          'run',
          'test/fixtures/workspace_lock_attempt.dart',
          directory.path,
          '${directory.path}/work',
          'install-stable',
        ],
        workingDirectory: Directory.current.path,
      );
      final exitCode =
          await child.exitCode.timeout(const Duration(seconds: 15));
      expect(exitCode, 0,
          reason: 'the second process must report the existing owner lock');
      expect(serviceOwner.isRunning, isTrue);
    } finally {
      await serviceOwner.stop();
      await directory.delete(recursive: true);
    }
  });
}
