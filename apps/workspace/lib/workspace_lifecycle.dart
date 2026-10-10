/// Independent lifecycle dimensions for the Workspace desktop runtime.
///
/// These values deliberately do not derive from one another. In particular,
/// human authentication says nothing about runtime participation, and the
/// local management lock says nothing about runtime connectivity.
enum HumanAuthState { signedOut, signedIn, reauthRequired }

enum WorkspaceParticipationState {
  disconnected,
  connecting,
  connected,
  disconnecting,
}

enum ManagementLockState { unlocked, locked }

/// The Cloud connection intent that should survive a service restart.
///
/// The older [DesiredRuntimeState] name is retained as a source-compatible
/// alias for local preference files and callers. It must not be confused with
/// the health of the local Workspace Service.
enum DesiredCloudConnectionState { connected, disconnected }

typedef DesiredRuntimeState = DesiredCloudConnectionState;

/// Full lifecycle snapshot that can be constructed and tested without UI state.
/// Transport health remains a separate [RuntimeTransportState] projection.
class WorkspaceLifecycleState {
  const WorkspaceLifecycleState({
    required this.humanAuth,
    required this.participation,
    required this.managementLock,
    DesiredRuntimeState? desiredRuntime,
    DesiredCloudConnectionState? desiredCloudState,
  }) : desiredRuntime = desiredCloudState ??
            desiredRuntime ??
            DesiredCloudConnectionState.disconnected;

  final HumanAuthState humanAuth;
  final WorkspaceParticipationState participation;
  final ManagementLockState managementLock;
  final DesiredRuntimeState desiredRuntime;

  /// Explicit semantic name for the persisted Cloud intent.
  DesiredCloudConnectionState get desiredCloudState => desiredRuntime;
}

/// Existing runtime transport projection; intentionally orthogonal to lifecycle.
enum RuntimeTransportState {
  websocket,
  httpLongPoll,
  reconnecting,
  offline,
  authenticationRequired,
}

/// Non-secret local preferences and non-authoritative owner display cache.
class WorkspaceLifecyclePreferences {
  const WorkspaceLifecyclePreferences({
    DesiredRuntimeState? desiredRuntime,
    DesiredCloudConnectionState? desiredCloudState,
    required this.launchAtLogin,
    required this.managementLockPreference,
    this.autoLockTimeout,
    this.ownerUserId,
    this.ownerDisplayName,
    this.customWorkspaceName,
    this.workRootPath,
  }) : desiredRuntime = desiredCloudState ??
            desiredRuntime ??
            DesiredCloudConnectionState.disconnected;

  WorkspaceLifecyclePreferences copyWith({
    DesiredRuntimeState? desiredRuntime,
    DesiredCloudConnectionState? desiredCloudState,
    bool? launchAtLogin,
    ManagementLockState? managementLockPreference,
    Duration? autoLockTimeout,
    String? ownerUserId,
    String? ownerDisplayName,
    String? customWorkspaceName,
    String? workRootPath,
  }) =>
      WorkspaceLifecyclePreferences(
        desiredRuntime:
            desiredCloudState ?? desiredRuntime ?? this.desiredRuntime,
        launchAtLogin: launchAtLogin ?? this.launchAtLogin,
        managementLockPreference:
            managementLockPreference ?? this.managementLockPreference,
        autoLockTimeout: autoLockTimeout ?? this.autoLockTimeout,
        ownerUserId: ownerUserId ?? this.ownerUserId,
        ownerDisplayName: ownerDisplayName ?? this.ownerDisplayName,
        customWorkspaceName: customWorkspaceName ?? this.customWorkspaceName,
        workRootPath: workRootPath ?? this.workRootPath,
      );

  final DesiredRuntimeState desiredRuntime;

  /// Persisted Cloud intent. The service process can be healthy regardless of
  /// this value and regardless of the current Cloud transport state.
  DesiredCloudConnectionState get desiredCloudState => desiredRuntime;
  final bool launchAtLogin;
  final ManagementLockState managementLockPreference;
  final Duration? autoLockTimeout;
  final String? ownerUserId;
  final String? ownerDisplayName;
  final String? customWorkspaceName;
  final String? workRootPath;

  /// Reset removes the local Workspace configuration while retaining user
  /// preferences and the non-authoritative owner cache as documented in ADR-014.
  factory WorkspaceLifecyclePreferences.afterLocalWorkspaceReset(
    WorkspaceLifecyclePreferences previous,
  ) =>
      WorkspaceLifecyclePreferences(
        desiredRuntime: DesiredRuntimeState.disconnected,
        launchAtLogin: previous.launchAtLogin,
        managementLockPreference: previous.managementLockPreference,
        autoLockTimeout: previous.autoLockTimeout,
        ownerUserId: previous.ownerUserId,
        ownerDisplayName: previous.ownerDisplayName,
        customWorkspaceName: previous.customWorkspaceName,
        workRootPath: previous.workRootPath,
      );
}
