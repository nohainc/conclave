/// Registration state reported by the native service host.
enum WorkspaceBackgroundServiceRegistration {
  unsupported,
  notRegistered,
  registered,
  approvalRequired,
  serviceMissing,
  unknown,
}

enum WorkspaceServiceProcessStatus {
  stopped,
  starting,
  running,
  stopping,
  failed,
  unknown,
}

enum WorkspaceServiceIpcStatus {
  unavailable,
  starting,
  ready,
  failed,
}

/// The authoritative host-side service snapshot.
///
/// Registration, process state, and authenticated IPC are separate facts. A
/// registered service can be stopped or failed, and a running process is not
/// considered usable until the IPC handshake succeeds.
class WorkspaceServiceInfo {
  const WorkspaceServiceInfo({
    required this.registration,
    required this.supported,
    required this.helperPresent,
    required this.plistPresent,
    this.launchSupported = true,
    this.process = WorkspaceServiceProcessStatus.unknown,
    this.pid,
    this.startedAt,
    this.version,
    this.ipc = WorkspaceServiceIpcStatus.unavailable,
    this.launchdState = 'unknown',
    this.lastExitCode,
    this.lastExitReason,
  });

  final WorkspaceBackgroundServiceRegistration registration;
  final bool supported;
  final bool helperPresent;
  final bool plistPresent;

  /// Whether this bundle has an Apple-trusted service helper that SMAppService
  /// can launch. Ad-hoc debug bundles intentionally report false.
  final bool launchSupported;
  final WorkspaceServiceProcessStatus process;
  final int? pid;
  final DateTime? startedAt;
  final String? version;
  final WorkspaceServiceIpcStatus ipc;

  /// Kept as a raw launchd value for diagnostics and compatibility.
  final String launchdState;
  final int? lastExitCode;
  final String? lastExitReason;

  bool get registered =>
      registration == WorkspaceBackgroundServiceRegistration.registered;

  bool get processRunning => process == WorkspaceServiceProcessStatus.running;

  bool get ipcReady => ipc == WorkspaceServiceIpcStatus.ready;

  bool get serviceHealthy => processRunning && ipcReady;

  bool get launchFailed =>
      process == WorkspaceServiceProcessStatus.failed ||
      (process == WorkspaceServiceProcessStatus.stopped &&
          lastExitReason != null);

  WorkspaceServiceInfo copyWith({
    WorkspaceBackgroundServiceRegistration? registration,
    bool? supported,
    bool? helperPresent,
    bool? plistPresent,
    bool? launchSupported,
    WorkspaceServiceProcessStatus? process,
    int? pid,
    bool clearPid = false,
    DateTime? startedAt,
    bool clearStartedAt = false,
    String? version,
    WorkspaceServiceIpcStatus? ipc,
    String? launchdState,
    int? lastExitCode,
    bool clearLastExitCode = false,
    String? lastExitReason,
    bool clearLastExitReason = false,
  }) {
    return WorkspaceServiceInfo(
      registration: registration ?? this.registration,
      supported: supported ?? this.supported,
      helperPresent: helperPresent ?? this.helperPresent,
      plistPresent: plistPresent ?? this.plistPresent,
      launchSupported: launchSupported ?? this.launchSupported,
      process: process ?? this.process,
      pid: clearPid ? null : pid ?? this.pid,
      startedAt: clearStartedAt ? null : startedAt ?? this.startedAt,
      version: version ?? this.version,
      ipc: ipc ?? this.ipc,
      launchdState: launchdState ?? this.launchdState,
      lastExitCode:
          clearLastExitCode ? null : lastExitCode ?? this.lastExitCode,
      lastExitReason:
          clearLastExitReason ? null : lastExitReason ?? this.lastExitReason,
    );
  }

  factory WorkspaceServiceInfo.fromNative(Map<Object?, Object?> value) {
    final registration = switch (value['registration']) {
      'unsupported' => WorkspaceBackgroundServiceRegistration.unsupported,
      'notRegistered' => WorkspaceBackgroundServiceRegistration.notRegistered,
      'registered' => WorkspaceBackgroundServiceRegistration.registered,
      'approvalRequired' =>
        WorkspaceBackgroundServiceRegistration.approvalRequired,
      'serviceMissing' => WorkspaceBackgroundServiceRegistration.serviceMissing,
      _ => WorkspaceBackgroundServiceRegistration.unknown,
    };
    final launchdState = value['launchdState'] is String
        ? value['launchdState'] as String
        : 'unknown';
    final process = switch (value['process']) {
      'stopped' => WorkspaceServiceProcessStatus.stopped,
      'starting' => WorkspaceServiceProcessStatus.starting,
      'running' => WorkspaceServiceProcessStatus.running,
      'stopping' => WorkspaceServiceProcessStatus.stopping,
      'failed' => WorkspaceServiceProcessStatus.failed,
      _ when launchdState == 'running' => WorkspaceServiceProcessStatus.running,
      _ when launchdState == 'stopped' || launchdState == 'not running' =>
        (value['lastExitReason'] is String
            ? WorkspaceServiceProcessStatus.failed
            : WorkspaceServiceProcessStatus.stopped),
      _ => WorkspaceServiceProcessStatus.unknown,
    };
    final ipc = switch (value['ipc']) {
      'starting' => WorkspaceServiceIpcStatus.starting,
      'ready' => WorkspaceServiceIpcStatus.ready,
      'failed' => WorkspaceServiceIpcStatus.failed,
      _ => WorkspaceServiceIpcStatus.unavailable,
    };
    return WorkspaceServiceInfo(
      registration: registration,
      supported: value['supported'] == true,
      helperPresent: value['helperPresent'] == true,
      plistPresent: value['plistPresent'] == true,
      launchSupported: value['launchSupported'] != false,
      process: process,
      pid: value['pid'] is int ? value['pid'] as int : null,
      startedAt: DateTime.tryParse(value['startedAt']?.toString() ?? ''),
      version: value['version'] is String ? value['version'] as String : null,
      ipc: ipc,
      launchdState: launchdState,
      lastExitCode:
          value['lastExitCode'] is int ? value['lastExitCode'] as int : null,
      lastExitReason: value['lastExitReason'] is String
          ? value['lastExitReason'] as String
          : null,
    );
  }
}

/// Compatibility name retained for callers that consumed the original host
/// status model. New code should use [WorkspaceServiceInfo].
typedef WorkspaceBackgroundServiceStatus = WorkspaceServiceInfo;

/// OS boundary for the persistent Workspace Service. Cloud operations remain
/// separate and are owned by the service after it is running.
abstract class WorkspaceServiceManager {
  const WorkspaceServiceManager();

  Future<WorkspaceServiceInfo> getInfo();

  Future<WorkspaceServiceInfo> status();

  Future<WorkspaceServiceInfo> register();
  Future<WorkspaceServiceInfo> unregister();
  Future<WorkspaceServiceInfo> start();
  Future<WorkspaceServiceInfo> stop();
  Future<WorkspaceServiceInfo> restart();
  Future<void> openSettings();
}

/// Used where a host service manager has not been implemented.
class UnsupportedWorkspaceServiceManager extends WorkspaceServiceManager {
  const UnsupportedWorkspaceServiceManager();

  @override
  Future<WorkspaceServiceInfo> getInfo() async => const WorkspaceServiceInfo(
        registration: WorkspaceBackgroundServiceRegistration.unsupported,
        supported: false,
        helperPresent: false,
        plistPresent: false,
        launchSupported: false,
      );

  @override
  Future<WorkspaceServiceInfo> status() => getInfo();

  UnsupportedError _unsupported() => UnsupportedError(
      'Background service management is not available on this platform.');

  @override
  Future<WorkspaceServiceInfo> register() => Future.error(_unsupported());

  @override
  Future<WorkspaceServiceInfo> unregister() => Future.error(_unsupported());

  @override
  Future<WorkspaceServiceInfo> start() => Future.error(_unsupported());

  @override
  Future<WorkspaceServiceInfo> stop() => Future.error(_unsupported());

  @override
  Future<WorkspaceServiceInfo> restart() => Future.error(_unsupported());

  @override
  Future<void> openSettings() => Future.error(_unsupported());
}
