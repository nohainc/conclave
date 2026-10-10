/// Authoritative lifecycle dimensions shared by the Workspace service and its
/// management client. Each dimension is independent: a healthy local service
/// may have a disconnected Cloud connection.
enum ServiceInstallationState {
  unsupported,
  notRegistered,
  approvalRequired,
  registered,
  serviceMissing,
  unknown,
}

enum ServiceRuntimeState {
  stopped,
  starting,
  running,
  stopping,
  failed,
  unknown,
}

enum CloudConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

class WorkspaceServiceLifecycle {
  const WorkspaceServiceLifecycle({
    required this.installation,
    required this.runtime,
    required this.cloud,
    required this.ipcReady,
    this.pid,
    this.startedAt,
    this.lastError,
  });

  final ServiceInstallationState installation;
  final ServiceRuntimeState runtime;
  final CloudConnectionState cloud;
  final bool ipcReady;
  final int? pid;
  final DateTime? startedAt;
  final String? lastError;

  bool get serviceHealthy => runtime == ServiceRuntimeState.running && ipcReady;

  bool get canConnect =>
      serviceHealthy && cloud != CloudConnectionState.connected;

  bool get canManageWorkers => serviceHealthy;
}
