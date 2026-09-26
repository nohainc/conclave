import 'dart:async';

import 'package:conclave_host/main.dart';
import 'package:conclave_host/workspace_pairing_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('unpaired Workspace proposes computer name and allows editing',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    WorkspacePairingRequest? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostDashboard(
            snapshot: const HostUiSnapshot(
              mode: HostUiMode.firstLaunch,
              title: 'Connect this Workspace',
              detail: 'Pair this computer to Conclave AX.',
              workspaceName: 'Old Workspace Display Name',
              hostname: 'test-computer.local',
              paired: false,
            ),
            resolveComputerName: () async => 'Friendly Computer Name',
            onPairRequest: (request) async => submitted = request,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final nameField = find.widgetWithText(TextField, 'Workspace name');
    expect(tester.widget<TextField>(nameField).controller!.text,
        'Friendly Computer Name');
    expect(find.text('Suggested from this computer. You can change it.'),
        findsOneWidget);

    await tester.enterText(nameField, 'My Custom Workspace');
    await tester.enterText(
      find.widgetWithText(TextField, 'Pairing code'),
      'pair-code',
    );
    await tester.ensureVisible(find.text('Connect'));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(submitted?.workspaceName, 'My Custom Workspace');
    expect(submitted?.token, 'pair-code');
  });

  testWidgets('late computer-name lookup does not overwrite user edits',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final computerName = Completer<String>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostDashboard(
            snapshot: const HostUiSnapshot(
              mode: HostUiMode.firstLaunch,
              title: 'Connect this Workspace',
              detail: 'Pair this computer to Conclave AX.',
              hostname: 'test-computer.local',
              paired: false,
            ),
            resolveComputerName: () => computerName.future,
          ),
        ),
      ),
    );
    await tester.pump();

    final nameField = find.widgetWithText(TextField, 'Workspace name');
    expect(
        tester.widget<TextField>(nameField).controller!.text, 'test-computer');
    await tester.enterText(nameField, 'User Chosen Name');

    computerName.complete('Friendly Computer Name');
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(nameField).controller!.text,
        'User Chosen Name');
  });
}
