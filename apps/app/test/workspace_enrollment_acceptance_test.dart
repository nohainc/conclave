import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:conclave_app/src/features/navigation/app_menu.dart';
import 'package:conclave_app/src/features/navigation/studio_shell_context.dart';
import 'package:conclave_app/src/features/workspace/workspaces_page.dart';
import 'package:conclave_app/src/navigation/studio_navigation.dart';
import 'package:conclave_app/src/studio/studio_data.dart';
import 'package:conclave_app/src/studio/studio_models.dart';

void main() {
  Widget scaffold(Widget child) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: child),
        ),
      );

  const initialWorkspace = StudioWorkspace(
    id: 'workspace-1',
    name: 'MacBook Pro',
    hostname: '—',
    status: 'not_connected',
    appVersion: '—',
    workerCount: 0,
    activeTaskCount: 0,
    platform: '—',
    architecture: '—',
  );

  group('Phase 10: Workspace Enrollment Acceptance', () {
    test('Enrollment code is created only on explicit Connect machine action',
        () async {
      final paths = <String>[];
      final api = StudioApiClient(
        baseUrl: 'https://cloud.test/api',
        client: MockClient((request) async {
          paths.add(request.url.path);
          return http.Response(
            jsonEncode({
              'id': 'enrollment-1',
              'token': 'XK82-PQ71',
              'workspaceId': 'workspace-1',
              'expiresAt': '2026-09-27T12:00:00Z',
            }),
            201,
          );
        }),
      );

      final enrollment = await api.createWorkspaceEnrollment(
        workspaceId: initialWorkspace.id,
      );

      expect(enrollment.token, 'XK82-PQ71');
      expect(paths, ['/api/workspaces/workspace-1/enrollments']);
    });

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
      expect(find.text('Pairing code'), findsNothing);

      // 2. Transition State: Pairing
      const pairingWorkspace = StudioWorkspace(
        id: 'workspace-1',
        name: 'MacBook Pro',
        hostname: '—',
        status: 'pairing',
        appVersion: '—',
        workerCount: 0,
        activeTaskCount: 0,
        platform: '—',
        architecture: '—',
      );

      await tester.pumpWidget(scaffold(WorkspacesPage(
        workspaces: const [pairingWorkspace],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();
      expect(find.text('Pairing'), findsNWidgets(2));
      expect(find.text('Machine'), findsOneWidget);

      // 3. Runtime Connected: Online with automatically populated platform facts
      const onlineWorkspace = StudioWorkspace(
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
                  shellContext: const StudioShellContext(
                    navigation: StudioNavigation.workspaces(),
                    workspaces: [initialWorkspace],
                    projects: [],
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
        final agent = StudioWorkspace(
          id: 'ws-test',
          name: 'Target Machine',
          hostname: 'host-1',
          status: 'online',
          appVersion: '1.0.0',
          workerCount: 0,
          activeTaskCount: 0,
          platform: os,
          architecture: arch,
        );

        await tester.pumpWidget(scaffold(WorkspacesPage(
          workspaces: [agent],
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

    test(
        'Re-enrollment refreshes machine facts while preserving logical entity',
        () {
      final initial = StudioWorkspace.fromJson({
        'id': 'workspace-1',
        'name': 'Development Rig',
        'slug': 'development-rig',
        'status': 'offline',
        'role': 'owner',
        'platform': 'linux',
        'architecture': 'x64',
        'hostname': 'rig-old',
        'appVersion': '1.0.1',
      });

      // Runtime is revoked and paired with updated hardware/software
      final reenrolled = StudioWorkspace.fromJson({
        'id': 'workspace-1',
        'name': 'Development Rig',
        'slug': 'development-rig',
        'status': 'online',
        'role': 'owner',
        'platform': 'macos',
        'architecture': 'arm64',
        'hostname': 'rig-apple-silicon',
        'appVersion': '1.0.3',
      });

      // Logical ID and identity remain identical
      expect(reenrolled.id, initial.id);
      expect(reenrolled.name, initial.name);
      expect(reenrolled.slug, initial.slug);

      // Runtime facts refresh
      expect(reenrolled.status, 'online');
      expect(reenrolled.platform, 'macos');
      expect(reenrolled.architecture, 'arm64');
      expect(reenrolled.hostname, 'rig-apple-silicon');
      expect(reenrolled.appVersion, '1.0.3');
    });
  });
}
