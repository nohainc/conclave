import 'package:conclave_app/src/features/common/collapsible_own_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(String data, {bool enabled = true, double width = 300}) =>
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: CollapsibleOwnMessage(
              data: data,
              enabled: enabled,
              child: const Text('Full Markdown'),
            ),
          ),
        ),
      );

  testWidgets('long own messages expand and collapse', (tester) async {
    await tester.pumpWidget(host('One\nTwo\nThree\nFour\nFive'));
    expect(find.text('Full Markdown'), findsNothing);
    await tester.tap(find.text('Show more'));
    await tester.pump();
    expect(find.text('Full Markdown'), findsOneWidget);
    await tester.tap(find.text('Hide more'));
    await tester.pump();
    expect(find.text('Full Markdown'), findsNothing);
    expect(find.text('Show more'), findsOneWidget);
  });

  testWidgets('short and other authors messages stay fully visible',
      (tester) async {
    await tester.pumpWidget(host('Short'));
    expect(find.text('Full Markdown'), findsOneWidget);
    expect(find.text('Show more'), findsNothing);
    await tester.pumpWidget(host('1\n2\n3\n4\n5', enabled: false));
    expect(find.text('Full Markdown'), findsOneWidget);
    expect(find.text('Show more'), findsNothing);
  });

  testWidgets(
      'wrapped long lines collapse and changed content resets expansion',
      (tester) async {
    await tester.pumpWidget(host(List.filled(100, 'word').join(' ')));
    await tester.tap(find.text('Show more'));
    await tester.pump();
    expect(find.text('Hide more'), findsOneWidget);
    await tester.pumpWidget(host('1\n2\n3\n4\n5'));
    expect(find.text('Show more'), findsOneWidget);
  });
}
