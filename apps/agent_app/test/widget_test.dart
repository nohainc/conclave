import 'package:conclave_agent_app/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders the Agent App scaffold', (tester) async {
    await tester.pumpWidget(const ConclaveAgentApp());

    expect(find.text('Conclave AX Agent'), findsOneWidget);
    expect(find.text('Agent Engine migration in progress'), findsOneWidget);
  });
}
