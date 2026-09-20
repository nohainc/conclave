import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/main.dart';

void main() {
  testWidgets('renders the shared Conclave shell', (WidgetTester tester) async {
    await tester.pumpWidget(const ConclaveApp());
    expect(find.text('Conclave'), findsOneWidget);
    expect(find.text('Platform: shared'), findsOneWidget);
  });
}
