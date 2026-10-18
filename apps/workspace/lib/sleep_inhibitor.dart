import 'dart:async';
import 'dart:io';

import 'workspace_lifecycle_store.dart';

/// Keeps the computer awake while the Workspace service runs and the
/// `preventSleep` preference is on. macOS uses `caffeinate -i -w <pid>`, so the
/// assertion is released by the OS even if the service is killed.
class SleepInhibitor {
  SleepInhibitor(
    this.store, {
    this.pollInterval = const Duration(seconds: 5),
    this.platformIsMacOS,
    this.start,
  });

  final WorkspaceLifecyclePreferencesStore store;
  final Duration pollInterval;
  final bool? platformIsMacOS;
  final Future<Process> Function(List<String> arguments)? start;

  Timer? _timer;
  Process? _process;
  bool _busy = false;

  bool get isHeld => _process != null;

  Future<void> begin() async {
    await _sync();
    _timer ??= Timer.periodic(pollInterval, (_) => _sync());
  }

  Future<void> _sync() async {
    if (_busy) return;
    _busy = true;
    try {
      var wanted = true;
      try {
        wanted = store.readSync().preventSleep;
      } on Object {
        // Unreadable preferences fall back to the default (on).
      }
      if (wanted && _process == null && (platformIsMacOS ?? Platform.isMacOS)) {
        final arguments = ['-i', '-w', '$pid'];
        try {
          final process = await (start?.call(arguments) ??
              Process.start('/usr/bin/caffeinate', arguments));
          _process = process;
          unawaited(process.exitCode.then((_) {
            if (identical(_process, process)) _process = null;
          }));
        } on Object catch (error) {
          stderr.writeln('Prevent sleep unavailable: $error');
        }
      } else if (!wanted && _process != null) {
        _release();
      }
    } finally {
      _busy = false;
    }
  }

  void _release() {
    _process?.kill();
    _process = null;
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    _release();
  }
}
