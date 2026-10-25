import 'package:conclave_workspace/main.dart';
import 'package:conclave_workspace/workspace_manager_ipc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('adds a chosen folder after step-up and removes on confirm',
      (tester) async {
    final folders = <Map<String, Object?>>[];
    final sent = <String>[];
    final stepUps = <String>[];
    Future<Object?> command(String name,
        {Map<String, Object?> payload = const {}}) async {
      sent.add(name);
      switch (name) {
        case 'folders.add':
          folders.add({
            'id': 'folder-0000000000000001',
            'displayName': 'api',
            'path': payload['path'],
            'status': 'read_only',
          });
          return folders.last;
        case 'folders.remove':
          folders.clear();
          return {'removed': true};
      }
      return {'folders': List.of(folders)};
    }

    await tester.pumpWidget(wrap(AllowedFoldersCard(
      command: command,
      chooseDirectory: () async => '/Users/me/Projects/api',
      requireStepUp: (reason) async {
        stepUps.add(reason);
        return true;
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('No folders allowed.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('allowed-folders-add')));
    await tester.pumpAndSettle();
    expect(stepUps, hasLength(1));
    expect(sent, ['folders.list', 'folders.add', 'folders.list']);
    expect(find.text('api'), findsOneWidget);
    expect(find.text('/Users/me/Projects/api · Read only'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    expect(find.textContaining('stay on this computer'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.text('No folders allowed.'), findsOneWidget);
  });

  testWidgets('does not add when step-up is declined and shows service errors',
      (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(wrap(AllowedFoldersCard(
      command: (name, {payload = const {}}) async {
        sent.add(name);
        if (name == 'folders.list') {
          throw const WorkspaceManagerProtocolException(
              'protected', 'Work Root folders are already available.');
        }
        return null;
      },
      chooseDirectory: () async => '/tmp/x',
      requireStepUp: (_) async => false,
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Work Root folders are already available.'),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('allowed-folders-add')));
    await tester.pumpAndSettle();
    expect(sent, ['folders.list']);
  });

  testWidgets('is disabled while the service is unavailable', (tester) async {
    await tester.pumpWidget(wrap(AllowedFoldersCard(
      serviceAvailable: false,
      command: (name, {payload = const {}}) async => fail('no IPC expected'),
      chooseDirectory: () async => '/tmp/x',
    )));
    await tester.pumpAndSettle();
    expect(find.text('Start the service to manage allowed folders.'),
        findsOneWidget);
    expect(
        tester
            .widget<TextButton>(
                find.byKey(const ValueKey('allowed-folders-add')))
            .onPressed,
        isNull);
  });
}
