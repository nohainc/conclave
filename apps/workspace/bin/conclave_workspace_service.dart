import 'dart:async';
import 'dart:io';

import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:conclave_workspace/workspace.dart';
import 'package:conclave_workspace/workspace_configuration.dart';
import 'package:conclave_workspace/workspace_lifecycle.dart';
import 'package:conclave_workspace/workspace_lifecycle_store.dart';
import 'package:conclave_workspace/workspace_runtime.dart';
import 'package:conclave_workspace/workspace_manager_service.dart';

/// Headless Workspace service entry point. It imports only the Dart runtime
/// graph; Flutter is used by the separate desktop management application.
Future<void> main(List<String> args) async {
  setCurrentProcessName('conclave-service');
  final dataDirectory = WorkspaceConfig.resolveDataDirectory(args);
  final preferenceStore = WorkspaceLifecyclePreferencesStore(dataDirectory);
  final registration = WorkspaceRegistrationStore(dataDirectory).readSync();
  final config = WorkspaceConfig.fromArgs(args);
  await preferenceStore.migrateLegacyIfNeeded(
    hasRuntimeRegistrationAndCredential:
        registration != null && config.authToken?.isNotEmpty == true,
  );
  final desiredCloudState = preferenceStore.readSync().desiredCloudState;
  final runtime = await buildWorkspaceRuntime(config, restartArgs: args);
  final once = args.contains('--once');
  try {
    await runtime.start(
      connectCloud: false,
    );
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
    if (runtime.isRunning &&
        desiredCloudState == DesiredCloudConnectionState.connected) {
      unawaited(runtime.cloudConnection?.connect().catchError((Object error) {
            stderr.writeln('Workspace Cloud connection unavailable: $error');
          }) ??
          Future<void>.value());
    }
    final stopped = Completer<void>();
    void stopOnSignal(ProcessSignal _) {
      if (!stopped.isCompleted) stopped.complete();
    }

    final signals = [
      ProcessSignal.sigterm.watch().listen(stopOnSignal),
      ProcessSignal.sigint.watch().listen(stopOnSignal),
    ];
    try {
      await stopped.future;
    } finally {
      for (final signal in signals) {
        await signal.cancel();
      }
    }
  } finally {
    await manager.close();
    await manager.workspace.stop();
  }
}
