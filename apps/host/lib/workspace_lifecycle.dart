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
  });

  final DesiredRuntimeState desiredRuntime;
  final bool launchAtLogin;
  final ManagementLockState managementLockPreference;
  final Duration? autoLockTimeout;
  final String? ownerUserId;
  final String? ownerDisplayName;
}
