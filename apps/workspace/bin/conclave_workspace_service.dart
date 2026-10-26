import 'dart:async';
import 'dart:io';

import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:conclave_workspace/sleep_inhibitor.dart';
import 'package:conclave_workspace/workspace.dart';
import 'package:conclave_workspace/workspace_lifecycle_store.dart';
import 'package:conclave_workspace/workspace_runtime.dart';
import 'package:conclave_workspace/workspace_manager_service.dart';
import 'package:conclave_workspace/workspace_settings.dart';

/// Headless Workspace service entry point. It imports only the Dart runtime
/// graph; Flutter is used by the separate desktop management application.
Future<void> main(List<String> args) async {
  setCurrentProcessName('conclave-workspace');
  initializeWindowsProcessJob();
  final dataDirectory = WorkspaceConfig.resolveDataDirectory(args);
  final initialStop = File('${dataDirectory.path}/runtime/stop-request');
  if (Platform.isWindows && initialStop.existsSync()) initialStop.deleteSync();
  final preferenceStore = WorkspaceLifecyclePreferencesStore(dataDirectory);
  await WorkspaceSettingsStore(dataDirectory).ensureDefaults();
  final config = WorkspaceConfig.fromArgs(args);
  if (!config.serviceEnabled) {
    stdout.writeln('Workspace is disabled in ${config.settingsFile?.path}.');
    return;
  }
  final runtime = await buildWorkspaceRuntime(config, restartArgs: args);
  final once = args.contains('--once');
  final sleepInhibitor = SleepInhibitor(preferenceStore);
  if (!once) await sleepInhibitor.begin();
  try {
    await runtime.start(connectCloud: false);
  } on Object catch (error) {
    // Publish failed initialization through IPC for management diagnostics.
    // A failed runtime must not start a Cloud execution connection.
    stderr.writeln('Workspace service initialization failed: $error');
  }
  final manager = WorkspaceManagerService(
    runtime,
    reloadRuntime: () async {
      final refreshedConfig = WorkspaceConfig.fromArgs(args);
      return buildWorkspaceRuntime(refreshedConfig, restartArgs: args);
    },
  );
  try {
    await manager.start();
    if (once) return;
    // Local management must become available before a slow/offline Cloud
    // handshake. Transport recovery remains owned by the service.
    if (runtime.isRunning && config.connectOnStart) {
      unawaited(
        runtime.cloudConnection?.connect().catchError((Object error) {
            stderr.writeln('Workspace Cloud connection unavailable: $error');
          }) ??
            Future<void>.value(),
      );
    }
    final stopped = Completer<void>();
    void stopOnSignal(ProcessSignal _) {
      if (!stopped.isCompleted) stopped.complete();
    }

    final stopRequest = File('${dataDirectory.path}/runtime/stop-request');
    final stopTimer = Platform.isWindows
        ? Timer.periodic(const Duration(milliseconds: 250), (_) {
            if (stopRequest.existsSync() && !stopped.isCompleted) {
              stopped.complete();
            }
          })
        : null;
    final signals = [
      if (!Platform.isWindows)
        ProcessSignal.sigterm.watch().listen(stopOnSignal),
      ProcessSignal.sigint.watch().listen(stopOnSignal),
    ];
    try {
      await stopped.future;
    } finally {
      stopTimer?.cancel();
      for (final signal in signals) {
        await signal.cancel();
      }
    }
  } finally {
    await sleepInhibitor.close();
    await manager.close();
    await manager.workspace.stop();
  }
}
