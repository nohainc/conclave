/// Native registration state for the embedded macOS Workspace LaunchAgent.
/// Registration is not treated as proof that the service process is running;
/// the manager must verify that separately over local IPC.
enum WorkspaceBackgroundServiceRegistration {
  unsupported,
  notRegistered,
  registered,
  approvalRequired,
  serviceMissing,
  unknown,
}

class WorkspaceBackgroundServiceStatus {
  const WorkspaceBackgroundServiceStatus({
    required this.registration,
    required this.supported,
    required this.helperPresent,
    required this.plistPresent,
  });

  final WorkspaceBackgroundServiceRegistration registration;
  final bool supported;
  final bool helperPresent;
  final bool plistPresent;

  factory WorkspaceBackgroundServiceStatus.fromNative(
    Map<Object?, Object?> value,
  ) {
    final status = switch (value['registration']) {
      'unsupported' => WorkspaceBackgroundServiceRegistration.unsupported,
      'notRegistered' => WorkspaceBackgroundServiceRegistration.notRegistered,
      'registered' => WorkspaceBackgroundServiceRegistration.registered,
      'approvalRequired' =>
        WorkspaceBackgroundServiceRegistration.approvalRequired,
      'serviceMissing' => WorkspaceBackgroundServiceRegistration.serviceMissing,
      _ => WorkspaceBackgroundServiceRegistration.unknown,
    };
    return WorkspaceBackgroundServiceStatus(
      registration: status,
      supported: value['supported'] == true,
      helperPresent: value['helperPresent'] == true,
      plistPresent: value['plistPresent'] == true,
    );
  }
}

/// OS boundary for registering and inspecting the persistent Workspace
/// Service. Platform-specific launch mechanisms belong in adapters, not in
/// runtime, Cloud, or Worker Engine code.
abstract interface class WorkspaceServiceManager {
  Future<WorkspaceBackgroundServiceStatus> status();
  Future<WorkspaceBackgroundServiceStatus> register();
  Future<WorkspaceBackgroundServiceStatus> unregister();
  Future<void> openSettings();
}

/// Used where a host service manager has not been implemented.
class UnsupportedWorkspaceServiceManager implements WorkspaceServiceManager {
  const UnsupportedWorkspaceServiceManager();

  @override
  Future<WorkspaceBackgroundServiceStatus> status() async =>
      const WorkspaceBackgroundServiceStatus(
        registration: WorkspaceBackgroundServiceRegistration.unsupported,
        supported: false,
        helperPresent: false,
        plistPresent: false,
      );

  @override
  Future<WorkspaceBackgroundServiceStatus> register() =>
      Future.error(UnsupportedError(
          'Background service management is not available on this platform.'));

  @override
  Future<WorkspaceBackgroundServiceStatus> unregister() =>
      Future.error(UnsupportedError(
          'Background service management is not available on this platform.'));

  @override
  Future<void> openSettings() => Future.error(UnsupportedError(
      'Background service settings are not available on this platform.'));
}
