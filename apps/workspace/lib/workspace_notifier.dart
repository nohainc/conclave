/// Small synchronous listener primitive shared by the headless runtime and UI.
/// It deliberately avoids Flutter foundation so runtime composition can be
/// imported by the standalone service executable.
class WorkspaceNotifier {
  final Set<void Function()> _listeners = {};
  bool _disposed = false;

  void addListener(void Function() listener) {
    if (_disposed) return;
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void notifyListeners() {
    if (_disposed) return;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  void dispose() {
    _disposed = true;
    _listeners.clear();
  }
}
