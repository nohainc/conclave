import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/features/navigation/app_menu.dart';
import 'package:conclave_app/src/features/navigation/ax_shell_context.dart';
import 'package:conclave_app/src/features/workspace/workspaces_page.dart';
import 'package:conclave_app/src/navigation/ax_navigation.dart';
import 'package:conclave_app/src/ax/ax_models.dart';

void main() {
  Widget scaffold(Widget child) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: child),
        ),
      );

  const initialWorkspace = AxWorkspace(
    id: 'workspace-1',
    name: 'MacBook Pro',
    hostname: '—',
    status: 'offline',
    hasRuntimeIdentity: false,
    appVersion: '—',
    workerCount: 0,
    activeTaskCount: 0,
    platform: '—',
    architecture: '—',
  );

  group('Workspace connection status', () {
    testWidgets(
        'Workspace operational status progresses from not connected to online',
        (tester) async {
      // 1. Initial State: Not connected. AX only observes this state.
      await tester.pumpWidget(scaffold(WorkspacesPage(
        workspaces: const [initialWorkspace],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Connection status'), findsOneWidget);
      expect(find.text('Not connected'), findsNWidgets(2));
      expect(find.text('Machine'), findsOneWidget);
      expect(find.text('Connect Machine'), findsNothing);

      // Runtime Connected: Online with automatically populated platform facts
      const onlineWorkspace = AxWorkspace(
        id: 'workspace-1',
        name: 'MacBook Pro',
        hostname: 'Vitalii-MacBook-Pro',
        status: 'online',
        appVersion: '1.0.3',
        workerCount: 2,
        activeTaskCount: 0,
        platform: 'macos',
        architecture: 'arm64',
        runtimeCapabilities: ['dart', 'shell'],
      );

      await tester.pumpWidget(scaffold(WorkspacesPage(
        workspaces: const [onlineWorkspace],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();
      expect(find.text('Online'), findsNWidgets(2));
      expect(find.text('Machine'), findsOneWidget);
      expect(find.text('macOS · Apple Silicon'), findsOneWidget);
      expect(find.text('Hostname'), findsOneWidget);
      expect(find.text('Vitalii-MacBook-Pro'), findsOneWidget);
      expect(find.text('App version'), findsOneWidget);
      expect(find.text('1.0.3'), findsOneWidget);
    });

    testWidgets('Download navigation resolves consistently across entrypoints',
        (tester) async {
      var downloadsOpenedCount = 0;
      Uri? openedExternalUri;

      // 1. Download link from Connect Machine flow in Workspace Detail
      await tester.pumpWidget(scaffold(WorkspacesPage(
        workspaces: const [initialWorkspace],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
        onOpenDownloads: () => downloadsOpenedCount++,
      )));
      await tester.pumpAndSettle();

      expect(find.text('Download Conclave Workspace'), findsOneWidget);
      await tester
          .ensureVisible(find.text('Download Conclave Workspace').first);
      await tester.tap(find.text('Download Conclave Workspace').first);
      expect(downloadsOpenedCount, 1);

      // 2. Global application menu documentation entrypoint
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                GlobalAppMenu(
                  shellContext: const AxShellContext(
                    navigation: AxNavigation.workspaces(),
                    workspaces: [initialWorkspace],
                    spaces: [],
                    themeMode: ThemeMode.system,
                  ),
                  onNavigateTo: (_) {},
                  onOpenAbout: () {},
                  onOpenExternal: (uri) => openedExternalUri = uri,
                  onLogout: () {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Application menu'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Documentation'));
      await tester.pumpAndSettle();
      expect(
          openedExternalUri, Uri.parse('https://conclaveax.com/how-it-works/'));
    });

    testWidgets('Platform reporting maps runtime OS and architectures cleanly',
        (tester) async {
      final platforms = [
        ('macos', 'arm64', 'macOS · Apple Silicon'),
        ('macos', 'x64', 'macOS · x64'),
        ('linux', 'x64', 'Linux · x64'),
        ('windows', 'x64', 'Windows · x64'),
        ('—', '—', '—'),
      ];

      for (final (os, arch, expectedLabel) in platforms) {
        final workspace = AxWorkspace(
          id: 'ws-test',
          name: 'Target Machine',
          hostname: 'workspace-node-1',
          status: 'online',
          appVersion: '1.0.0',
          workerCount: 0,
          activeTaskCount: 0,
          platform: os,
          architecture: arch,
        );

        await tester.pumpWidget(scaffold(WorkspacesPage(
          workspaces: [workspace],
          onAdd: () {},
          onRename: (_) {},
          onUpdate: (_) {},
          onRevoke: (_) {},
          onGrant: (_) {},
        )));
        await tester.pumpAndSettle();
        expect(find.text(expectedLabel), findsWidgets);
      }
    });
  });
}
