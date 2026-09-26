import 'package:conclave_host/workspace_pairing_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'WorkspacePairingDialog pre-populates proposed workspace name and allows editing',
      (tester) async {
    WorkspacePairingRequest? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showWorkspacePairingDialog(
                  context,
                  initialWorkspaceName: "Vitalii's MacBook Pro",
                );
              },
              child: const Text('Open Dialog'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Dialog'));
    await tester.pumpAndSettle();

    // Verify dialog title and fields
    expect(find.text('Pair Conclave Workspace'), findsOneWidget);
    expect(find.text('Workspace display name'), findsOneWidget);
    expect(find.text("Vitalii's MacBook Pro"), findsOneWidget);

    // Enter pairing code
    await tester.enterText(
      find.widgetWithText(TextField, 'Pairing code'),
      'one-time-token-123',
    );

    // Tap Pair button
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.workspaceName, "Vitalii's MacBook Pro");
    expect(result!.token, 'one-time-token-123');
  });

  testWidgets(
      'WorkspacePairingDialog allows customizing workspace name before pairing',
      (tester) async {
    WorkspacePairingRequest? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showWorkspacePairingDialog(
                  context,
                  initialWorkspaceName: "Vitalii's MacBook Pro",
                );
              },
              child: const Text('Open Dialog'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Dialog'));
    await tester.pumpAndSettle();

    // Edit workspace name
    await tester.enterText(
      find.widgetWithText(TextField, 'Workspace display name'),
      'Design Team M3 Max',
    );

    // Enter pairing code
    await tester.enterText(
      find.widgetWithText(TextField, 'Pairing code'),
      'code-xyz',
    );

    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.workspaceName, 'Design Team M3 Max');
    expect(result!.token, 'code-xyz');
  });

  testWidgets(
      'WorkspacePairingDialog validates missing workspace name and pairing code',
      (tester) async {
    WorkspacePairingRequest? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showWorkspacePairingDialog(
                  context,
                  initialWorkspaceName: '',
                );
              },
              child: const Text('Open Dialog'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Dialog'));
    await tester.pumpAndSettle();

    // Tap Pair with empty name and empty code
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a workspace display name.'), findsOneWidget);
    expect(result, isNull);

    // Enter workspace name but leave token empty
    await tester.enterText(
      find.widgetWithText(TextField, 'Workspace display name'),
      'Primary Mac',
    );
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(
        find.text('Enter the pairing code from Conclave AX.'), findsOneWidget);
    expect(result, isNull);
  });
}
