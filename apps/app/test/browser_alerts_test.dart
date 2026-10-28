import 'package:syntila_app/src/notifications/browser_alerts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool alert({
    bool read = false,
    bool tabVisible = true,
    bool viewingRun = false,
    bool viewingThread = false,
  }) =>
      shouldShowBrowserAlert(
          read: read,
          tabVisible: tabVisible,
          viewingRun: viewingRun,
          viewingThread: viewingThread);

  test('alerts in a visible tab when the item is not on screen', () {
    expect(alert(), isTrue);
  });

  test('alerts in a hidden tab, even for the open Thread or Run', () {
    expect(alert(tabVisible: false), isTrue);
    expect(alert(tabVisible: false, viewingThread: true), isTrue);
    expect(alert(tabVisible: false, viewingRun: true), isTrue);
  });

  test('stays quiet for the Thread or Run being viewed in a visible tab', () {
    expect(alert(viewingThread: true), isFalse);
    expect(alert(viewingRun: true), isFalse);
  });

  test('stays quiet for already-read notifications', () {
    expect(alert(read: true, tabVisible: false), isFalse);
  });
}
