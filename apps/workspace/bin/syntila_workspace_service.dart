import 'dart:async';
import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_workspace/sleep_inhibitor.dart';
import 'package:syntila_workspace/workspace.dart';
import 'package:syntila_workspace/workspace_lifecycle_store.dart';
import 'package:syntila_workspace/workspace_runtime.dart';
import 'package:syntila_workspace/workspace_manager_service.dart';
import 'package:syntila_workspace/workspace_settings.dart';

/// Headless Workspace service entry point. It imports only the Dart runtime
/// graph; Flutter is used by the separate desktop management application.
Future<void> main(List<String> args) async {
  setCurrentProcessName('syntila');
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
    // systemd gives the unit `TimeoutStopSec` to exit after SIGTERM and then
    // sends SIGKILL, which makes `service stop` hang and the unit end as
    // failed. Each step is bounded and reported, and a watchdog forces the
    // exit if teardown still has not finished.
    final watchdog = Timer(_shutdownDeadline, () {
      stderr.writeln(
        'Workspace shutdown exceeded ${_shutdownDeadline.inSeconds}s; exiting.',
      );
      exit(0);
    });
    await _boundedShutdownStep('sleep inhibitor', sleepInhibitor.close);
    await _boundedShutdownStep('management server', manager.close);
    await _boundedShutdownStep('workspace', manager.workspace.stop);
    watchdog.cancel();
  }
}

/// Must stay below the systemd unit's `TimeoutStopSec`.
const _shutdownDeadline = Duration(seconds: 15);
const _shutdownStepTimeout = Duration(seconds: 6);

Future<void> _boundedShutdownStep(
  String name,
  Future<void> Function() step,
) async {
  try {
    await step().timeout(_shutdownStepTimeout);
  } on TimeoutException {
    stderr.writeln('Workspace shutdown: $name did not finish in '
        '${_shutdownStepTimeout.inSeconds}s; continuing.');
  } on Object catch (error) {
    stderr.writeln('Workspace shutdown: $name failed: $error');
  }
}
