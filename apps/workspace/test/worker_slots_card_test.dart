import 'package:conclave_workspace/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(
          body: child,
        ),
      );

  testWidgets(
      'capacity stays visible offline without IPC and refreshes on restart',
      (tester) async {
    var reads = 0;
    Future<Map<String, Object?>> load() async {
      reads++;
      return {
        'active': 1,
        'queued': 0,
        'limit': 4,
        'activeAssignmentIds': ['a']
      };
    }

    Widget view(bool available) => wrap(WorkerSlotsCard(
          serviceAvailable: available,
          load: load,
          setSlots: (_) async => {},
          reset: () async => {},
        ));
    await tester.pumpWidget(view(true));
    await tester.pump();
    expect(reads, 1);
    await tester.pumpWidget(view(false));
    await tester.pump(const Duration(seconds: 6));
    expect(reads, 1);
    expect(find.text('Parallel executions'), findsOneWidget);
    expect(find.text('Slots 1/4 in use'), findsOneWidget);
    expect(
        tester
            .widget<DropdownButtonFormField<int>>(
                find.byKey(const ValueKey('parallel-slots-select')))
            .onChanged,
        isNull);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Reset slots'))
            .onPressed,
        isNull);
    await tester.pumpWidget(view(true));
    await tester.pump();
    expect(reads, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'WorkerSlotsCard renders usage line, waiting line, 8+ warning, and out-of-sync note',
      (tester) async {
    var payload = <String, Object?>{
      'active': 1,
      'queued': 0,
      'limit': 4,
      'activeAssignmentIds': <String>['a-1'],
    };

    await tester.pumpWidget(
      wrap(
        WorkerSlotsCard(
          load: () async => payload,
          reset: () async => payload,
          setSlots: (slots) async {
            payload = <String, Object?>{
              ...payload,
              'limit': slots,
            };
            return payload;
          },
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('parallel-slots-usage')),
      findsOneWidget,
    );
    expect(find.text('Slots 1/4 in use'), findsOneWidget);
    expect(
        tester.widget<Text>(find.text('Parallel executions')).style?.fontWeight,
        FontWeight.w400);
    final reset = find.widgetWithText(TextButton, 'Reset slots');
    expect(reset, findsOneWidget);
    expect(tester.getCenter(reset).dy,
        closeTo(tester.getCenter(find.text('Slots 1/4 in use')).dy, 1));

    expect(find.textContaining('Maximum simultaneous requests'), findsNothing);
    final selector = find.byKey(const ValueKey('parallel-slots-select'));
    expect(tester.getCenter(selector).dy,
        closeTo(tester.getCenter(find.text('Parallel executions')).dy, 1));
    expect(tester.getCenter(selector).dx,
        greaterThan(tester.getCenter(find.text('Parallel executions')).dx));
    expect(find.byKey(const ValueKey('parallel-slots-waiting')), findsNothing);
    expect(
      find.byKey(const ValueKey('parallel-slots-high-warning')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('parallel-slots-out-of-sync')),
      findsNothing,
    );

    // 1 waiting request
    payload = <String, Object?>{
      'active': 4,
      'queued': 1,
      'limit': 4,
      'activeAssignmentIds': <String>['a-1', 'a-2', 'a-3', 'a-4', 'a-5'],
    };
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Slots 4/4 in use'), findsOneWidget);
    expect(find.text('Waiting for a free slot'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('parallel-slots-out-of-sync')),
      findsNothing,
    );

    // Multiple waiting requests + 7 slots (just below warning threshold)
    payload = <String, Object?>{
      'active': 7,
      'queued': 3,
      'limit': 7,
      'activeAssignmentIds': List<String>.generate(10, (i) => 'a-$i'),
    };
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Slots 7/7 in use'), findsOneWidget);
    expect(
      find.text('Waiting for a free slot · 3 requests'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('parallel-slots-high-warning')),
      findsNothing,
    );

    // High-value warning at 8+ slots via dropdown selection
    await tester.tap(find.byKey(const ValueKey('parallel-slots-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('8').last);
    await tester.pumpAndSettle();

    expect(find.text('Slots 7/8 in use'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('parallel-slots-high-warning')),
      findsOneWidget,
    );
    expect(
      find.text(
        'A high value can overload this computer and run into provider rate limits.',
      ),
      findsOneWidget,
    );

    // Out-of-sync note when trackedIds != active + queued
    payload = <String, Object?>{
      'active': 2,
      'queued': 0,
      'limit': 8,
      'activeAssignmentIds': <String>['a-1'],
    };
    await tester.pump(const Duration(seconds: 3));
    expect(
      find.byKey(const ValueKey('parallel-slots-out-of-sync')),
      findsOneWidget,
    );
    expect(
      find.text(
        'Slot usage looks out of sync. Use Reset slots if work does not start.',
      ),
      findsOneWidget,
    );
  });
}
