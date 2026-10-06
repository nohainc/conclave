@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/navigation/ax_browser_navigation.dart';

void main() {
  test('native browser connectivity emits offline/online and removes listeners',
      () async {
    final navigation = createAxBrowserNavigation();
    final network = navigation as AxBrowserConnectivity;
    expect(network.online, html.window.navigator.onLine);
    final events = <bool>[];
    final subscription = network.connectivityChanges.listen(events.add);
    html.window.dispatchEvent(html.Event('offline'));
    html.window.dispatchEvent(html.Event('online'));
    expect(events, [false, true]);
    navigation.dispose();
    await Future<void>.delayed(Duration.zero);
    html.window.dispatchEvent(html.Event('offline'));
    expect(events, [false, true]);
    await subscription.cancel();
  });

  test('native visibility notifications only emit for a visible document',
      () async {
    final navigation = createAxBrowserNavigation();
    var events = 0;
    final subscription = navigation.lifecycleChanges.listen((_) => events++);
    html.document.dispatchEvent(html.Event('visibilitychange'));
    expect(events, html.document.visibilityState == 'visible' ? 1 : 0);
    await subscription.cancel();
    navigation.dispose();
  });
}
