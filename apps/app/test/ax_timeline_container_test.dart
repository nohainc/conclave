import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/features/spaces/spaces_pages.dart';

void main() {
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
