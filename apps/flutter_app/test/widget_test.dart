import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/main.dart';

void main() {
  testWidgets('renders the Studio run dashboard', (WidgetTester tester) async {
    await tester.pumpWidget(const ConclaveApp());
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('Build a useful Conclave Studio UI'), findsWidgets);
    expect(find.text('Execution tree'), findsOneWidget);
    expect(find.text('Evidence & findings'), findsOneWidget);
  });

  testWidgets('can pause a run and open goal creation',
      (WidgetTester tester) async {
    await tester.pumpWidget(const ConclaveApp());

    await tester.tap(find.text('Pause'));
    await tester.pump();
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Paused'), findsOneWidget);

    await tester.tap(find.text('New goal'));
    await tester.pump();
    expect(find.text('Create a goal'), findsOneWidget);
    expect(find.text('What should Conclave accomplish?'), findsOneWidget);
  });
}
