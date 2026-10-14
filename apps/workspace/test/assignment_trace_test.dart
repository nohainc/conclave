import 'dart:async';

import 'package:conclave_workspace/assignment_trace.dart';
import 'package:test/test.dart';

void main() {
  group('ClockOffsetEstimator', () {
    test('has no estimate before the first sample', () {
      final estimator = ClockOffsetEstimator();
      expect(estimator.hasEstimate, isFalse);
      expect(estimator.offsetMs, isNull);
      expect(estimator.roundTripMs, isNull);
    });

    test('centers Cloud time inside the measured round trip', () {
      final estimator = ClockOffsetEstimator();
      final sentAt = DateTime.utc(2026, 10, 14, 10, 0, 0);
      // Cloud clock is 500 ms ahead; the request took 100 ms round trip.
      estimator.addSample(
        sentAtUtc: sentAt,
        roundTrip: const Duration(milliseconds: 100),
        serverTimeUtc: sentAt.add(const Duration(milliseconds: 550)),
      );
      expect(estimator.offsetMs, 500);
      expect(estimator.roundTripMs, 100);
    });

    test('prefers the sample with the smallest round trip', () {
      final estimator = ClockOffsetEstimator();
      final sentAt = DateTime.utc(2026, 10, 14, 10, 0, 0);
      estimator.addSample(
        sentAtUtc: sentAt,
        roundTrip: const Duration(milliseconds: 800),
        serverTimeUtc: sentAt.add(const Duration(milliseconds: 1000)),
      );
      estimator.addSample(
        sentAtUtc: sentAt,
        roundTrip: const Duration(milliseconds: 40),
        serverTimeUtc: sentAt.add(const Duration(milliseconds: 20 - 300)),
      );
      expect(estimator.roundTripMs, 40);
      expect(estimator.offsetMs, -300);
    });

    test('keeps only the most recent window of samples', () {
      final estimator = ClockOffsetEstimator(window: 2);
      final sentAt = DateTime.utc(2026, 10, 14, 10, 0, 0);
      estimator.addSample(
        sentAtUtc: sentAt,
        roundTrip: const Duration(milliseconds: 1),
        serverTimeUtc: sentAt,
      );
      for (var i = 0; i < 2; i++) {
        estimator.addSample(
          sentAtUtc: sentAt,
          roundTrip: const Duration(milliseconds: 50),
          serverTimeUtc: sentAt,
        );
      }
      expect(estimator.roundTripMs, 50);
    });

    test('ignores negative round trips', () {
      final estimator = ClockOffsetEstimator();
      estimator.addSample(
        sentAtUtc: DateTime.utc(2026),
        roundTrip: const Duration(milliseconds: -1),
        serverTimeUtc: DateTime.utc(2026),
      );
      expect(estimator.hasEstimate, isFalse);
    });
  });

  group('LatencyHistogram', () {
    test('reports no percentiles when empty', () {
      final histogram = LatencyHistogram();
      expect(histogram.count, 0);
      expect(histogram.percentileMs(50), isNull);
      expect(histogram.toJson()['meanMs'], isNull);
    });

    test('summarizes p50, p95 and p99 conservatively by bucket', () {
      final histogram = LatencyHistogram();
      for (var i = 0; i < 90; i++) {
        histogram.record(8);
      }
      for (var i = 0; i < 9; i++) {
        histogram.record(150);
      }
      histogram.record(4000);
      expect(histogram.count, 100);
      expect(histogram.percentileMs(50), 10);
      expect(histogram.percentileMs(95), 200);
      expect(histogram.percentileMs(99), 200);
      expect(histogram.percentileMs(100), 4000);
      expect(histogram.maxMs, 4000);
    });

    test('never reports a percentile above the observed maximum', () {
      final histogram = LatencyHistogram()..record(3);
      expect(histogram.percentileMs(99), 3);
    });

    test('counts samples beyond the largest bucket and clamps negatives', () {
      final histogram = LatencyHistogram()
        ..record(-5)
        ..record(10 * 60 * 1000 + 1);
      expect(histogram.percentileMs(50), lessThanOrEqualTo(1));
      expect(histogram.percentileMs(100), 10 * 60 * 1000 + 1);
    });
  });

  group('AssignmentTraceRecorder', () {
    test('records ordered stages once and feeds interval histograms', () {
      final recorder = AssignmentTraceRecorder();
      final first = recorder.begin('a-1', note: 'ready');
      expect(first, isNotNull);
      expect(first!.stage, 'service_received');
      expect(recorder.noteOf('a-1'), 'ready');

      final accepted = recorder.mark('a-1', 'service_accepted');
      expect(accepted, isNotNull);
      expect(accepted!.sinceLastMs, greaterThanOrEqualTo(0));
      expect(recorder.mark('a-1', 'service_accepted'), isNull);
      expect(recorder.mark('a-1', 'slot_reserved'), isNotNull);

      final summary = recorder.summaryJson();
      expect(summary.keys, contains('service_received->service_accepted'));
      expect(summary.keys, contains('service_accepted->slot_reserved'));
      expect(summary.keys, contains('since_received:slot_reserved'));
    });

    test('ignores unknown assignments and replayed begins', () {
      final recorder = AssignmentTraceRecorder();
      expect(recorder.mark('missing', 'service_accepted'), isNull);
      expect(recorder.begin('a-1'), isNotNull);
      expect(recorder.begin('a-1'), isNull);
    });

    test('bounds open traces by evicting the oldest', () {
      final recorder = AssignmentTraceRecorder(maxActive: 2);
      recorder
        ..begin('a-1')
        ..begin('a-2')
        ..begin('a-3');
      expect(recorder.activeTraceCount, 2);
      expect(recorder.isTracking('a-1'), isFalse);
      expect(recorder.isTracking('a-3'), isTrue);
    });

    test('finish releases the trace but keeps histograms', () {
      final recorder = AssignmentTraceRecorder()
        ..begin('a-1')
        ..mark('a-1', 'service_accepted')
        ..finish('a-1');
      expect(recorder.activeTraceCount, 0);
      expect(recorder.summaryJson(), isNotEmpty);
    });
  });

  group('runDetachedTelemetry', () {
    test('does not wait for a slow action', () {
      final never = Completer<void>();
      final stopwatch = Stopwatch()..start();
      runDetachedTelemetry(() => never.future);
      expect(stopwatch.elapsedMilliseconds, lessThan(50));
    });

    test('swallows synchronous and asynchronous failures', () async {
      runDetachedTelemetry(() => throw StateError('sync'));
      runDetachedTelemetry(() async => throw StateError('async'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  });
}
