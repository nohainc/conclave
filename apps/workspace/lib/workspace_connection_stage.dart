/// Cloud connection progress as projected to management clients.
///
/// Kept separate from `cloud_connection.dart` so the Flutter management UI can
/// render connection state without importing the service-owned Cloud runtime.
enum WorkspaceConnectionStage {
  validating,
  offline,
  connecting,
  authenticating,
  synchronizing,
  ready,
  reconnecting,
  switchingToWebSocket,
}
