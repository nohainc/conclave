import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syntila_app/src/features/spaces/spaces_pages.dart';

void main() {
  testWidgets('appending a fifth row keeps the gap across the anchor tight',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var count = 4;
    Widget timeline() => MaterialApp(
          home: Scaffold(
              body: AxTimelineContainer(
            scrollKey: const ValueKey('timeline'),
            controller: controller,
            itemCount: count,
            itemId: (index) => 'row-$index',
            separatorBuilder: (_, __) => const SizedBox(height: 2),
            itemBuilder: (_, index) => SizedBox(
                key: ValueKey('row-$index'),
                height: 40,
                child: Text('Message $index')),
          )),
        );
    await tester.pumpWidget(timeline());
    await tester.pumpAndSettle();
    count = 5;
    await tester.pumpWidget(timeline());
    await tester.pumpAndSettle();
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    for (var index = 1; index < count; index++) {
      expect(
          tester.getTopLeft(find.byKey(ValueKey('row-$index'))).dy -
              tester.getBottomLeft(find.byKey(ValueKey('row-${index - 1}'))).dy,
          closeTo(2, 0.01),
          reason: 'gap before message $index');
    }
  });
  testWidgets('virtualizes large variable-height timelines', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var built = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 400,
          child: AxTimelineContainer(
            scrollKey: const ValueKey('timeline'),
            controller: controller,
            itemCount: 5000,
            itemBuilder: (context, index) {
              built++;
              return SizedBox(
                key: ValueKey('entry-$index'),
                height: index.isEven ? 48 : 120,
                child: Text('Entry $index'),
              );
            },
          ),
        ),
      ),
    );

    expect(built, lessThan(100));
    expect(find.byKey(const ValueKey('entry-4999')), findsNothing);

    await tester.drag(
        find.byKey(const ValueKey('timeline')), const Offset(0, -800));
    await tester.pump();
    expect(built, lessThan(180));
  });
}
