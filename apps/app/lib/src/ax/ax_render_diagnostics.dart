import 'dart:async';

import 'package:flutter/foundation.dart';

/// Bounded, privacy-safe diagnostics for AX rendering and realtime lifecycle
/// failures. The reporter keeps only recent metadata in memory and never
/// stores provider prompts, model output, tool arguments, or credentials.
class AxRenderDiagnostics {
  AxRenderDiagnostics({this.sink});

  static final instance = AxRenderDiagnostics();

  final void Function(Map<String, Object?> record)? sink;
  final _recent = <Map<String, Object?>>[];
  final _context = <String, Object?>{};
  FlutterExceptionHandler? _previousFlutterError;
  bool Function(Object error, StackTrace stack)? _previousPlatformError;
  bool _installed = false;
  bool _reporting = false;
  bool _reportedDisposedView = false;
  bool _reportedDetachedPlatformView = false;

  /// Whether [details] is the engine assertion raised when a frame is rendered
  /// into an already disposed `EngineFlutterView`.
  @visibleForTesting
  static bool isDisposedViewRenderError(FlutterErrorDetails details) => details
      .exceptionAsString()
      .contains('Trying to render a disposed EngineFlutterView');

  /// Whether [details] is the debug-only framework assertion raised when a
  /// platform view's post-frame position update runs after its render object
  /// was detached (`localToGlobal` in `platform_view.dart`). It happens when
  /// the view is removed in the same frame, asserts are compiled out of
  /// release builds, and it is raised inside the framework, not by app code.
  @visibleForTesting
  static bool isDetachedPlatformViewError(FlutterErrorDetails details) {
    final stack = details.stack?.toString() ?? '';
    return details.exception is AssertionError &&
        stack.contains('platform_view.dart') &&
        stack.contains('localToGlobal') &&
        details.exceptionAsString().contains('attached');
  }

  List<Map<String, Object?>> get recent => List.unmodifiable(_recent);

  void install() {
    if (_installed) return;
    _installed = true;
    _previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      // After a web hot restart (or when the tab replaces the view) the
      // engine keeps scheduling frames for the disposed view and every one
      // throws this assertion. It is a debug-only engine artifact, not an app
      // failure: report it once per session and do not dump it each frame.
      if (isDisposedViewRenderError(details)) {
        if (!_reportedDisposedView) {
          _reportedDisposedView = true;
          record('exception', contextData: {
            'category': 'disposed_view_render',
            'error': 'Frame requested for a disposed Flutter view; '
                'ignored (usually a web hot restart). Reload the tab.',
          });
        }
        return;
      }
      if (isDetachedPlatformViewError(details)) {
        if (!_reportedDetachedPlatformView) {
          _reportedDetachedPlatformView = true;
          record('exception', contextData: {
            'category': 'detached_platform_view',
            'error': 'A platform view updated its position after it was '
                'removed; ignored (debug-only framework assertion).',
          });
        }
        return;
      }
      captureFlutterError(details);
      _previousFlutterError?.call(details);
    };
    _previousPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      captureException(
        category: 'async_exception',
        error: error,
        stack: stack,
      );
      return _previousPlatformError?.call(error, stack) ?? false;
    };
  }

  void updateContext({
    String? threadId,
    String? tab,
    String? eventType,
    String? requestId,
    String? component,
    bool? mounted,
    bool? disposed,
  }) {
    _setOrRemove('threadId', threadId);
    _setOrRemove('tab', tab);
    _setOrRemove('eventType', eventType);
    _setOrRemove('requestId', requestId);
    _setOrRemove('component', component);
    if (mounted != null) _context['mounted'] = mounted;
    if (disposed != null) _context['disposed'] = disposed;
  }

  void realtimeEvent(Map<String, dynamic> event) {
    final payload = event['payload'];
    final payloadMap = payload is Map ? payload : const <Object?, Object?>{};
    updateContext(
      threadId: _stringValue(event['threadId']) ??
          _stringValue(payloadMap['threadId']),
      eventType: _stringValue(event['type']),
      requestId: _stringValue(payloadMap['workRequestId']) ??
          _stringValue(payloadMap['requestId']),
      component: 'realtime',
    );
    record('realtime.event');
  }

  void cacheMutation({
    required String component,
    required String operation,
    String? threadId,
    String? requestId,
  }) {
    updateContext(
      component: component,
      threadId: threadId,
      requestId: requestId,
    );
    record('cache.mutation', operation: operation);
  }

  void notifierDispatch({required String component, String? operation}) {
    updateContext(component: component);
    record('notifier.dispatch', operation: operation);
  }

  void widgetRebuild(
      {required String component, String? threadId, String? tab}) {
    updateContext(component: component, threadId: threadId, tab: tab);
    record('widget.rebuild');
  }

  void captureFlutterError(FlutterErrorDetails details) {
    final category = _frameworkCategory(details);
    captureException(
      category: category,
      error: details.exception,
      stack: details.stack,
      operation: details.library,
      contextData: {
        if (details.context != null)
          'frameworkContext': details.context.toString(),
        if (details.informationCollector != null) 'hasDiagnostics': true,
      },
    );
  }

  void captureException({
    required String category,
    required Object error,
    StackTrace? stack,
    String? operation,
    Map<String, Object?> contextData = const {},
  }) {
    record(
      'exception',
      operation: operation,
      contextData: {
        'category': category,
        'errorType': error.runtimeType.toString(),
        'error': _safeText(error.toString()),
        if (stack != null) 'stack': _safeStack(stack),
        ...contextData,
      },
    );
  }

  void record(
    String event, {
    String? operation,
    Map<String, Object?> contextData = const {},
  }) {
    if (_reporting) return;
    _reporting = true;
    try {
      final record = <String, Object?>{
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'event': event,
        if (operation != null) 'operation': operation,
        ..._context,
        ...contextData,
      };
      _recent.add(Map.unmodifiable(record));
      if (_recent.length > 256) _recent.removeAt(0);
      sink?.call(record);
      if (kDebugMode && event == 'exception') {
        debugPrint('[AX render] ${record['category']}: ${record['error']}');
      }
    } finally {
      _reporting = false;
    }
  }

  void _setOrRemove(String key, String? value) {
    if (value == null || value.isEmpty) {
      _context.remove(key);
    } else {
      _context[key] = value.length > 128 ? value.substring(0, 128) : value;
    }
  }

  static String? _stringValue(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static String _frameworkCategory(FlutterErrorDetails details) {
    final text = details.exceptionAsString();
    if (text.contains('setState() or markNeedsBuild() called during build')) {
      return 'build_phase_notification';
    }
    if (text.contains('setState() called after dispose()')) {
      return 'use_after_dispose';
    }
    if (text.contains('ScrollController not attached')) {
      return 'scroll_not_attached';
    }
    if (text.contains('RenderBox was not laid out')) {
      return 'layout_failure';
    }
    if (text.contains('Duplicate GlobalKey')) return 'duplicate_global_key';
    if (text.contains('RangeError')) return 'stale_index';
    return 'framework_exception';
  }

  static String _safeText(String value) {
    final redacted = value.replaceAllMapped(
      RegExp(
          r'(prompt|token|secret|password|api[_-]?key|credential)\s*[:=]\s*[^,;\n]+',
          caseSensitive: false),
      (match) => '${match.group(1)}=[redacted]',
    );
    return redacted.length > 1024 ? redacted.substring(0, 1024) : redacted;
  }

  static String _safeStack(StackTrace stack) {
    final text = stack.toString();
    return text.length > 8192 ? text.substring(0, 8192) : text;
  }
}

/// Keeps a guarded async zone around the application entrypoint.
void runSyntilaApp(void Function() start) {
  AxRenderDiagnostics.instance.install();
  runZonedGuarded(start, (error, stack) {
    AxRenderDiagnostics.instance.captureException(
      category: 'async_exception',
      error: error,
      stack: stack,
    );
  });
}
