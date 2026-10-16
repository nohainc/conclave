import 'browser_alerts.dart';

AxBrowserAlerts createAxBrowserAlerts() => const _UnsupportedAlerts();

class _UnsupportedAlerts implements AxBrowserAlerts {
  const _UnsupportedAlerts();

  @override
  bool get supported => false;

  @override
  bool get enabled => false;

  @override
  Future<bool> enable() async => false;

  @override
  void disable() {}

  @override
  void show({
    required String title,
    required String body,
    required String tag,
    required void Function() onClick,
  }) {}
}
