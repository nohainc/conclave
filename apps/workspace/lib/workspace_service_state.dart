import 'dart:convert';
import 'dart:io';

import 'cloud_connection.dart';

enum WorkspaceServiceProcessState {
  starting,
  initializing,
  ready,
  stopping,
  stopped,
  failed,
}

enum WorkspaceServiceCloudState {
  notConfigured,
  authenticationRequired,
  disconnected,
  connecting,
  connected,
  reconnecting,
}

enum WorkspaceServiceExecutionState { idle, executing }

/// A persisted operational snapshot. Process health and Cloud transport are
/// intentionally separate so an offline Workspace can still be healthy.
class WorkspaceServiceState {
  const WorkspaceServiceState({
    required this.processState,
    required this.cloudState,
    required this.installationId,
    required this.updatedAt,
    this.startedAt,
    this.executionState = WorkspaceServiceExecutionState.idle,
    this.activeAssignments = 0,
    this.failure,
  });

  final WorkspaceServiceProcessState processState;
  final WorkspaceServiceCloudState cloudState;
  final String? installationId;
  final DateTime updatedAt;
  final DateTime? startedAt;
  final WorkspaceServiceExecutionState executionState;
  final int activeAssignments;
  final String? failure;

  Map<String, Object?> toJson() => {
        'processState': processState.name,
        'cloudState': cloudState.name,
        if (installationId != null) 'installationId': installationId,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        if (startedAt != null)
          'startedAt': startedAt!.toUtc().toIso8601String(),
        'executionState': executionState.name,
        'activeAssignments': activeAssignments,
        if (failure != null) 'failure': failure,
      };

  static WorkspaceServiceCloudState cloudStateFor({
    required bool configured,
    required bool authenticated,
    required WorkspaceConnectionStage? stage,
  }) {
    if (!configured) {
      return WorkspaceServiceCloudState.notConfigured;
    }
    if (!authenticated) {
      return WorkspaceServiceCloudState.authenticationRequired;
    }
    return switch (stage) {
      WorkspaceConnectionStage.ready => WorkspaceServiceCloudState.connected,
      WorkspaceConnectionStage.connecting ||
      WorkspaceConnectionStage.validating ||
      WorkspaceConnectionStage.authenticating ||
      WorkspaceConnectionStage.synchronizing ||
      WorkspaceConnectionStage.switchingToWebSocket =>
        WorkspaceServiceCloudState.connecting,
      WorkspaceConnectionStage.reconnecting =>
        WorkspaceServiceCloudState.reconnecting,
      WorkspaceConnectionStage.offline ||
      null =>
        WorkspaceServiceCloudState.disconnected,
    };
  }
}

Future<void> writeWorkspaceServiceState(
  Directory dataDirectory,
  WorkspaceServiceState state,
) async {
  await dataDirectory.create(recursive: true);
  final target = File('${dataDirectory.path}/workspace-state.json');
  final temporary = File('${target.path}.tmp');
  await temporary.writeAsString(jsonEncode(state.toJson()), flush: true);
  await temporary.rename(target.path);
}
