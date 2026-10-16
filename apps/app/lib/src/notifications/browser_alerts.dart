import 'browser_alerts_stub.dart'
    if (dart.library.js_interop) 'browser_alerts_web.dart' as platform;

/// Opt-in desktop alerts for a hidden browser tab. Cloud never sees the
/// choice: the permission is the browser's and the switch is local.
abstract interface class AxBrowserAlerts {
  bool get supported;

  /// True when the user turned alerts on and the browser permits them.
  bool get enabled;

  /// Asks the browser for permission when needed; returns the new [enabled].
  Future<bool> enable();

  void disable();

  /// Shows an alert; [onClick] runs when the user selects it.
  void show({
    required String title,
    required String body,
    required String tag,
    required void Function() onClick,
  });
}

AxBrowserAlerts createAxBrowserAlerts() => platform.createAxBrowserAlerts();
