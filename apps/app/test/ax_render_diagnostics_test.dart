import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syntila_app/src/ax/ax_render_diagnostics.dart';

void main() {
  test('captures framework exceptions with lifecycle and request context', () {
    final records = <Map<String, Object?>>[];
    final diagnostics = AxRenderDiagnostics(sink: records.add);
    diagnostics.updateContext(
      threadId: 'thread-1',
      tab: 'work',
      eventType: 'assignment.activity',
      requestId: 'request-1',
      component: 'ThreadPage',
      mounted: false,
      disposed: true,
    );

    diagnostics.captureFlutterError(
      FlutterErrorDetails(
        exception: FlutterError('setState() called after dispose()'),
        stack:
            StackTrace.fromString('at ThreadPage._callback (thread.dart:42)'),
        library: 'widgets library',
      ),
    );

    final record = records.single;
    expect(record['event'], 'exception');
    expect(record['category'], 'use_after_dispose');
    expect(record['threadId'], 'thread-1');
    expect(record['tab'], 'work');
    expect(record['requestId'], 'request-1');
    expect(record['component'], 'ThreadPage');
    expect(record['mounted'], isFalse);
    expect(record['disposed'], isTrue);
    expect(record['stack'], contains('ThreadPage._callback'));
  });

  test('classifies the targeted Flutter exception signatures', () {
    final diagnostics = AxRenderDiagnostics();
    const cases = {
      'setState() or markNeedsBuild() called during build':
          'build_phase_notification',
      'setState() called after dispose()': 'use_after_dispose',
      'ScrollController not attached': 'scroll_not_attached',
      'RenderBox was not laid out': 'layout_failure',
      'Duplicate GlobalKey detected': 'duplicate_global_key',
      'RangeError (index)': 'stale_index',
    };

    for (final entry in cases.entries) {
      final records = <Map<String, Object?>>[];
      final current = AxRenderDiagnostics(sink: records.add);
      current.captureFlutterError(
        FlutterErrorDetails(
          exception: FlutterError(entry.key),
          stack: StackTrace.fromString('stack for ${entry.key}'),
        ),
      );
      expect(records.single['category'], entry.value);
      expect(records.single['stack'], contains('stack for'));
      // Keep the shared instance exercised too; it must not affect the
      // isolated reporter used by the assertion above.
      diagnostics.record('signature.checked', operation: entry.value);
    }
  });

  test('redacts sensitive values and bounds retained diagnostics', () {
    final diagnostics = AxRenderDiagnostics();
    diagnostics.captureException(
      category: 'async_exception',
      error: StateError('prompt=private text token=secret-value'),
      stack: StackTrace.fromString('sensitive stack'),
    );

    final first = diagnostics.recent.single;
    expect(first['error'], isNot(contains('private text')));
    expect(first['error'], isNot(contains('secret-value')));
    expect(first['stack'], contains('sensitive stack'));

    for (var index = 0; index < 300; index++) {
      diagnostics.record('lifecycle', operation: 'event-$index');
    }
    expect(diagnostics.recent, hasLength(256));
    expect(diagnostics.recent.first['operation'], 'event-44');
  });

  test('records realtime, cache, notifier and rebuild context', () {
    final records = <Map<String, Object?>>[];
    final diagnostics = AxRenderDiagnostics(sink: records.add);
    diagnostics.realtimeEvent({
      'type': 'assignment.activity',
      'threadId': 'thread-1',
      'payload': {'workRequestId': 'request-1'},
    });
    diagnostics.cacheMutation(
      component: 'AxWorkRealtimeSync',
      operation: 'assignment.activity',
      threadId: 'thread-1',
      requestId: 'request-1',
    );
    diagnostics.notifierDispatch(
      component: 'AxWorkRealtimeSync',
      operation: 'activity',
    );
    diagnostics.widgetRebuild(
      component: 'ThreadPage',
      threadId: 'thread-1',
      tab: 'work',
    );

    expect(records.map((record) => record['event']), [
      'realtime.event',
      'cache.mutation',
      'notifier.dispatch',
      'widget.rebuild',
    ]);
    expect(records.last['threadId'], 'thread-1');
    expect(records.last['tab'], 'work');
  });

  test('recognizes the disposed-view render assertion only', () {
    expect(
      AxRenderDiagnostics.isDisposedViewRenderError(
        FlutterErrorDetails(
          exception: AssertionError(
            'Trying to render a disposed EngineFlutterView.',
          ),
        ),
      ),
      isTrue,
    );
    expect(
      AxRenderDiagnostics.isDisposedViewRenderError(
        FlutterErrorDetails(
          exception: FlutterError('setState() called after dispose()'),
        ),
      ),
      isFalse,
    );
  });

  test('recognizes the detached platform view assertion only', () {
    final platformStack = StackTrace.fromString(
      'package:flutter/src/rendering/box.dart 3092:39 localToGlobal\n'
      'package:flutter/src/widgets/platform_view.dart 1608:22 <fn>',
    );
    expect(
      AxRenderDiagnostics.isDetachedPlatformViewError(
        FlutterErrorDetails(
          exception: AssertionError('attached\nis not true'),
          stack: platformStack,
        ),
      ),
      isTrue,
    );
    // Same assertion from app or other framework code is still reported.
    expect(
      AxRenderDiagnostics.isDetachedPlatformViewError(
        FlutterErrorDetails(
          exception: AssertionError('attached\nis not true'),
          stack: StackTrace.fromString('package:app/x.dart 1:1 build'),
        ),
      ),
      isFalse,
    );
  });
}
