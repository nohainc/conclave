import 'dart:async';

/// Cloud supports application ping/pong. Lack of a pong detects a silently
/// stalled socket without treating an idle Thread as a disconnected one.
class RealtimeHealthMonitor {
  RealtimeHealthMonitor(
      {required this.ping,
      required this.onStale,
      this.interval = const Duration(seconds: 20),
      this.timeout = const Duration(seconds: 10)});
  final void Function() ping;
  final void Function() onStale;
  final Duration interval;
  final Duration timeout;
  Timer? _heartbeat;
  Timer? _deadline;
  void start() {
    stop();
    _heartbeat = Timer.periodic(interval, (_) {
      if (_deadline != null) return;
      _deadline = Timer(timeout, () {
        stop();
        onStale();
      });
      ping();
    });
  }

  void acknowledge() {
    _deadline?.cancel();
    _deadline = null;
  }

  void stop() {
    _heartbeat?.cancel();
    _deadline?.cancel();
    _heartbeat = null;
    _deadline = null;
  }
}
