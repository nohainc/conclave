import 'package:flutter_test/flutter_test.dart';

import 'package:syntila_app/src/ax/ax_status_settler.dart';

void main() {
  final t0 = DateTime.utc(2026, 1, 1, 12);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  test('a fast sequence of pre-start statuses shows only the neutral line', () {
    final settler = AxStatusSettler();
    expect(settler.update('Queued · A', at(0), urgent: false), 'Starting…');
    expect(settler.update('Queued · B', at(100), urgent: false), 'Starting…');
    expect(settler.update('Starting · C', at(250), urgent: false), 'Starting…');
    // The provider starts before anything settled: shown immediately.
    expect(settler.update('Running · Working…', at(300), urgent: true),
        'Running · Working…');
    expect(settler.nextCheck, isNull);
  });

  test('a status that stays is shown once it settles', () {
    final settler = AxStatusSettler();
    const waiting = 'Queued · Waiting for an available Worker slot';
    expect(settler.update(waiting, at(0), urgent: false), 'Starting…');
    expect(settler.nextCheck, const Duration(milliseconds: 700));
    expect(settler.update(waiting, at(500), urgent: false), 'Starting…');
    expect(settler.nextCheck, const Duration(milliseconds: 200));
    expect(settler.update(waiting, at(700), urgent: false), waiting);
    expect(settler.nextCheck, isNull);
  });

  test('a changing status restarts the settle timer', () {
    final settler = AxStatusSettler();
    settler.update('A', at(0), urgent: false);
    settler.update('B', at(600), urgent: false);
    // B has only been pending 200 ms even though A started at 0.
    expect(settler.update('B', at(800), urgent: false), 'Starting…');
    expect(settler.update('B', at(1300), urgent: false), 'B');
  });

  test('a shown status stays for the minimum display time', () {
    final settler = AxStatusSettler(
      settleDelay: const Duration(milliseconds: 100),
      minDisplay: const Duration(milliseconds: 600),
    );
    settler.update('A', at(0), urgent: false);
    expect(settler.update('A', at(100), urgent: false), 'Starting…');
    // A is displayed from 600 ms (min display of the neutral line).
    expect(settler.update('A', at(600), urgent: false), 'A');
    settler.update('B', at(700), urgent: false);
    expect(settler.update('B', at(900), urgent: false), 'A');
    expect(settler.update('B', at(1100), urgent: false), 'A');
    expect(settler.update('B', at(1200), urgent: false), 'B');
  });

  test('going back to what is shown cancels the pending change', () {
    final settler = AxStatusSettler();
    settler.update('A', at(0), urgent: false);
    settler.update('Starting…', at(300), urgent: false);
    expect(settler.nextCheck, isNull);
    expect(settler.update('Starting…', at(2000), urgent: false), 'Starting…');
  });

  test('urgent updates show immediately and null clears the line', () {
    final settler = AxStatusSettler();
    settler.update('Queued', at(0), urgent: false);
    expect(settler.update('Failed', at(50), urgent: true), 'Failed');
    expect(settler.displayed, 'Failed');
    expect(settler.update(null, at(60), urgent: false), isNull);
    expect(settler.displayed, isNull);
  });
}
