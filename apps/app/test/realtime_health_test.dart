import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/realtime/realtime_health.dart';

void main() {
  testWidgets('idle healthy socket keeps pinging without marking Work stale',
      (tester) async {
    var pings = 0, stale = 0;
    final monitor =
        RealtimeHealthMonitor(ping: () => pings++, onStale: () => stale++);
    addTearDown(monitor.stop);
    monitor.start();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 20));
      monitor.acknowledge();
    }
    expect(pings, 4);
    expect(stale, 0);
    monitor.stop();
  });
  testWidgets(
      'missing pong reports one stale connection and stops the heartbeat',
      (tester) async {
    var pings = 0, stale = 0;
    final monitor =
        RealtimeHealthMonitor(ping: () => pings++, onStale: () => stale++);
    addTearDown(monitor.stop);
    monitor.start();
    await tester.pump(const Duration(seconds: 20));
    expect(pings, 1);
    expect(stale, 0);
    await tester.pump(const Duration(seconds: 9));
    expect(stale, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(stale, 1);
    await tester.pump(const Duration(seconds: 60));
    expect(pings, 1);
    expect(stale, 1);
  });
  testWidgets('stopping cancels pending heartbeat and pong timeout',
      (tester) async {
    var stale = 0;
    final monitor = RealtimeHealthMonitor(ping: () {}, onStale: () => stale++);
    monitor.start();
    await tester.pump(const Duration(seconds: 20));
    monitor.stop();
    await tester.pump(const Duration(seconds: 30));
    expect(stale, 0);
    monitor.start();
    await tester.pump(const Duration(seconds: 20));
    monitor.acknowledge();
    monitor.stop();
  });
}
