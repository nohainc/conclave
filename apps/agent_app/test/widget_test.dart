import 'package:conclave_agent_app/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders the Agent App scaffold', (tester) async {
    await tester.pumpWidget(
      ConclaveAgentApp(connection: AgentEngineConnection.unavailable()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Conclave AX Agent'), findsOneWidget);
    expect(find.text('Agent overview'), findsOneWidget);
    expect(find.text('Agent Engine offline'), findsOneWidget);
    expect(find.text('Workers'), findsNWidgets(2));
  });
}
