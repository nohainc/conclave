import 'package:conclave_app/src/ax/sync/ax_query_builder.dart';
import 'package:conclave_app/src/ax/sync/ax_sync_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('query notifications cannot mark a consumer dirty during build',
      (tester) async {
    final engine = AxSyncEngine();
    final query = AxQuery<int>(
      key: AxQueryKey(['query-builder-regression']),
      load: () async => 1,
    );
    final rebuild = ValueNotifier<int>(0);
    addTearDown(rebuild.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: rebuild,
          builder: (context, child) {
            if (rebuild.value > 0) {
              engine.update(query, (_) => 1);
            }
            return child!;
          },
          child: AxQueryBuilder<int>(
            engine: engine,
            query: query,
            ensure: false,
            builder: (context, state) => Text('${state.data ?? 0}'),
          ),
        ),
      ),
    );

    rebuild.value = 1;
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);
  });
}
