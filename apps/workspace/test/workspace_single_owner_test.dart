import 'dart:async';
import 'dart:io';

import 'package:conclave_workspace/workspace.dart';
import 'package:test/test.dart';

void main() {
  test('installation lock prevents two runtime owners from starting', () async {
    final directory =
        await Directory.systemTemp.createTemp('workspace-single-owner-');
    final state = Directory('${directory.path}/state');
    final config = WorkspaceConfig(
      dataDirectory: state,
      installationId: 'install-stable',
      workRootPath: '${directory.path}/work',
    );
    final serviceOwner = Workspace(config: config);
    Process? child;
    Future<void>? stdoutDrain;
    Future<void>? stderrDrain;
    var childExited = false;
    try {
      await serviceOwner.start();
      child = await Process.start(
        _dartExecutable(),
        [
          'run',
          'test/fixtures/workspace_lock_attempt.dart',
          state.path,
          '${directory.path}/work',
          'install-stable',
        ],
        workingDirectory: Directory.current.path,
      );
      stdoutDrain = child.stdout.drain<void>();
      stderrDrain = child.stderr.drain<void>();
      final exitCode = await child.exitCode
          .whenComplete(() => childExited = true)
          .timeout(const Duration(seconds: 15));
      await Future.wait([stdoutDrain, stderrDrain])
          .timeout(const Duration(seconds: 5));
      expect(exitCode, 0,
          reason: 'the second process must report the existing owner lock');
      expect(serviceOwner.isRunning, isTrue);
    } finally {
      try {
        if (child != null && !childExited) await _terminateChild(child);
        await Future.wait([
          if (stdoutDrain != null) stdoutDrain,
          if (stderrDrain != null) stderrDrain,
        ]).timeout(const Duration(seconds: 5));
      } finally {
        await serviceOwner.stop();
        await directory.delete(recursive: true);
      }
    }
  });

  test('fixture cleanup kills its exact child when graceful stop is ignored',
      () async {
    if (Platform.isWindows) return;
    final child = await Process.start('/bin/sh', [
      '-c',
      'trap "" TERM; printf ready; read ignored',
    ]);
    final stderrDrain = child.stderr.drain<void>();
    try {
      // The ready marker proves the child has installed its SIGTERM handler.
      await child.stdout.first.timeout(const Duration(seconds: 5));
      await _terminateChild(child, grace: const Duration(milliseconds: 100));
      expect(await child.exitCode, isNot(0));
    } finally {
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
      await stderrDrain;
    }
  });
}

String _dartExecutable() {
  final configured = Platform.environment['DART_EXECUTABLE']?.trim();
  if (configured != null && configured.isNotEmpty) {
    if (configured
        .replaceAll('\\', '/')
        .split('/')
        .last
        .startsWith('flutter_tester')) {
      throw StateError(
          'DART_EXECUTABLE must point to Dart, not flutter_tester');
    }
    return configured;
  }
  final lookup =
      Process.runSync(Platform.isWindows ? 'where' : 'which', ['dart']);
  if (lookup.exitCode == 0) {
    final paths = lookup.stdout.toString().split(RegExp(r'\r?\n'));
    for (final path in paths) {
      if (path.trim().isNotEmpty) return path.trim();
    }
  }
  throw StateError('Set DART_EXECUTABLE or put dart on PATH for this fixture');
}

Future<void> _terminateChild(Process child,
    {Duration grace = const Duration(seconds: 2)}) async {
  child.kill();
  try {
    await child.exitCode.timeout(grace);
  } on TimeoutException {
    child.kill(ProcessSignal.sigkill);
    await child.exitCode.timeout(const Duration(seconds: 5));
  }
}
