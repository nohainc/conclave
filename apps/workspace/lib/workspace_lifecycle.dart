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

enum DesiredRuntimeState { connected, disconnected }

bool shouldHideManagementWindowOnStartup({
  required bool isMacOS,
  required bool launchAtLogin,
}) =>
    isMacOS && launchAtLogin;

/// Full lifecycle snapshot that can be constructed and tested without UI state.
/// Transport health remains a separate [RuntimeTransportState] projection.
class WorkspaceLifecycleState {
  const WorkspaceLifecycleState({
    required this.humanAuth,
    required this.participation,
    required this.managementLock,
    required this.desiredRuntime,
  });

  final HumanAuthState humanAuth;
  final WorkspaceParticipationState participation;
  final ManagementLockState managementLock;
  final DesiredRuntimeState desiredRuntime;
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
    required this.desiredRuntime,
    required this.launchAtLogin,
    required this.managementLockPreference,
    this.autoLockTimeout,
    this.ownerUserId,
    this.ownerDisplayName,
    this.customWorkspaceName,
  });

  WorkspaceLifecyclePreferences copyWith({
    DesiredRuntimeState? desiredRuntime,
    bool? launchAtLogin,
    ManagementLockState? managementLockPreference,
    Duration? autoLockTimeout,
    String? ownerUserId,
    String? ownerDisplayName,
    String? customWorkspaceName,
  }) =>
      WorkspaceLifecyclePreferences(
        desiredRuntime: desiredRuntime ?? this.desiredRuntime,
        launchAtLogin: launchAtLogin ?? this.launchAtLogin,
        managementLockPreference:
            managementLockPreference ?? this.managementLockPreference,
        autoLockTimeout: autoLockTimeout ?? this.autoLockTimeout,
        ownerUserId: ownerUserId ?? this.ownerUserId,
        ownerDisplayName: ownerDisplayName ?? this.ownerDisplayName,
        customWorkspaceName: customWorkspaceName ?? this.customWorkspaceName,
      );

  final DesiredRuntimeState desiredRuntime;
  final bool launchAtLogin;
  final ManagementLockState managementLockPreference;
  final Duration? autoLockTimeout;
  final String? ownerUserId;
  final String? ownerDisplayName;
  final String? customWorkspaceName;

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
      );
}
