import 'dart:async';
import 'dart:io';

import 'package:conclave_workspace/cloud_connection.dart';
import 'package:conclave_workspace/workspace.dart';
import 'package:conclave_workspace/workspace_configuration.dart';
import 'package:conclave_workspace/workspace_lifecycle.dart';
import 'package:conclave_workspace/workspace_lifecycle_store.dart';
import 'package:conclave_workspace/workspace_runtime.dart';
import 'package:conclave_workspace/workspace_manager_service.dart';

/// Headless Workspace service entry point. It imports only the Dart runtime
/// graph; Flutter is used by the separate desktop management application.
Future<void> main(List<String> args) async {
  final dataDirectory = WorkspaceConfig.resolveDataDirectory(args);
  final preferenceStore = WorkspaceLifecyclePreferencesStore(dataDirectory);
  final registration = WorkspaceRegistrationStore(dataDirectory).readSync();
  final config = WorkspaceConfig.fromArgs(args);
  await preferenceStore.migrateLegacyIfNeeded(
    hasRuntimeRegistrationAndCredential:
        registration != null && config.authToken?.isNotEmpty == true,
  );
  final desiredRuntime = preferenceStore.readSync().desiredRuntime;
  final runtime = await buildWorkspaceRuntime(config, restartArgs: args);
  final once = args.contains('--once');
  try {
    await runtime.start(
      connectCloud: desiredRuntime == DesiredRuntimeState.connected,
    );
  } on Object catch (error) {
    // Keep the service process healthy while Cloud is unavailable. Cloud
    // transport recovery is retried below; local Workers and configuration
    // remain available for the next connection attempt.
    stderr.writeln('Workspace service started offline: $error');
  }
  final manager = WorkspaceManagerService(runtime);
  try {
    await manager.start();
    if (once) return;

    var retryDelay = const Duration(seconds: 2);
    while (runtime.isRunning) {
      await Future<void>.delayed(retryDelay);
      if (!runtime.isRunning) break;
      final connection = runtime.cloudConnection;
      if (connection == null ||
          preferenceStore.readSync().desiredRuntime !=
              DesiredRuntimeState.connected ||
          connection.connectionStage != WorkspaceConnectionStage.offline) {
        continue;
      }
      try {
        await connection.retryNow();
        retryDelay = const Duration(seconds: 2);
      } on Object catch (error) {
        final current = retryDelay.inSeconds;
        retryDelay = Duration(seconds: (current * 2).clamp(2, 60));
        stderr.writeln('Workspace Cloud reconnect failed: $error');
      }
    }
  } finally {
    await manager.close();
    await runtime.stop();
  }
}
