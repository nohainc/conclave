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

  const initialWorkspace = StudioAgent(
    id: 'workspace-1',
    name: 'MacBook Pro',
    hostname: '—',
    status: 'not_connected',
    version: '—',
    pluginCount: 0,
    workerCount: 0,
    activeTaskCount: 0,
    os: '—',
    architecture: '—',
    appVersion: '—',
  );

  group('Phase 10: Workspace Creation & Explicit Pairing Acceptance', () {
    test('Workspace creation requires only a name and does not imply a platform',
        () async {
      final requests = <http.BaseRequest>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.method == 'POST' && request.url.path == '/api/workspaces') {
          return http.Response(
            jsonEncode({
              'workspace': {
                'id': 'workspace-1',
                'name': 'MacBook Pro',
                'slug': 'macbook-pro',
                'status': 'not_connected',
                'role': 'owner',
              },
            }),
            201,
          );
        }
        return http.Response('{"error":"not_found"}', 404);
      });
      final api = StudioApiClient(
        baseUrl: 'https://cloud.test/api',
        client: client,
      );

      final created = await api.createWorkspace(name: 'MacBook Pro');

      expect(created.name, 'MacBook Pro');
      expect(created.status, 'not_connected');
      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/api/workspaces');

      final body = jsonDecode((requests.single as http.Request).body)
          as Map<String, dynamic>;
      expect(body.keys, ['name']);
      expect(body['name'], 'MacBook Pro');
      expect(body.containsKey('platform'), isFalse);
      expect(body.containsKey('os'), isFalse);
      expect(body.containsKey('architecture'), isFalse);

      expect(
        requests.any((req) => req.url.path.endsWith('/enrollments')),
        isFalse,
      );
    });

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

      final enrollment = await api.createHostEnrollment(
        workspaceId: initialWorkspace.id,
      );

      expect(enrollment.token, 'XK82-PQ71');
      expect(paths, ['/api/workspaces/workspace-1/enrollments']);
    });

    testWidgets(
        'Full Pairing Flow: Not connected -> Connect machine -> Pairing -> Online with platform',
        (tester) async {
      var connectMachineTriggered = false;

      // 1. Initial State: Not connected
      await tester.pumpWidget(scaffold(WorkspacesPage(
        workspaces: const [initialWorkspace],
        workers: const [],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
        onConnect: (_) async => connectMachineTriggered = true,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text('MacBook Pro'));
      await tester.pumpAndSettle();

      expect(find.text('Status: Not connected'), findsOneWidget);
      expect(find.text('Machine: —'), findsOneWidget);
      expect(find.text('Connect machine'), findsOneWidget);

      await tester.tap(find.text('Connect machine'));
      expect(connectMachineTriggered, isTrue);

      // 2. Transition State: Pairing
      const pairingWorkspace = StudioAgent(
        id: 'workspace-1',
        name: 'MacBook Pro',
        hostname: '—',
        status: 'pairing',
        version: '—',
        pluginCount: 0,
        workerCount: 0,
        activeTaskCount: 0,
        os: '—',
        architecture: '—',
        appVersion: '—',
      );

      await tester.pumpWidget(scaffold(WorkspacesPage(
        workspaces: const [pairingWorkspace],
        workers: const [],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MacBook Pro'));
      await tester.pumpAndSettle();

      expect(find.text('Status: Pairing'), findsOneWidget);
      expect(find.text('Machine: —'), findsOneWidget);

      // 3. Runtime Connected: Online with automatically populated platform facts
      const onlineWorkspace = StudioAgent(
        id: 'workspace-1',
        name: 'MacBook Pro',
        hostname: 'Vitalii-MacBook-Pro',
        status: 'online',
        version: '1.0.3',
        pluginCount: 1,
        workerCount: 2,
        activeTaskCount: 0,
        os: 'macos',
        architecture: 'arm64',
        appVersion: '1.0.3',
        runtimeCapabilities: ['dart', 'shell'],
      );

      await tester.pumpWidget(scaffold(WorkspacesPage(
        workspaces: const [onlineWorkspace],
        workers: const [],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MacBook Pro'));
      await tester.pumpAndSettle();

      expect(find.text('Status: Online'), findsOneWidget);
      expect(find.text('Machine: macOS · Apple Silicon'), findsOneWidget);
      expect(find.text('Hostname: Vitalii-MacBook-Pro'), findsOneWidget);
      expect(find.text('Conclave Workspace: 1.0.3'), findsOneWidget);
      expect(find.text('Runtime capabilities: dart, shell'), findsOneWidget);
    });

    testWidgets('Download navigation resolves consistently across entrypoints',
        (tester) async {
      var downloadsOpenedCount = 0;
      Uri? openedExternalUri;

      // 1. Download link from Connect Machine flow in Workspace Detail
      await tester.pumpWidget(scaffold(WorkspacesPage(
        workspaces: const [initialWorkspace],
        workers: const [],
        onAdd: () {},
        onRename: (_) {},
        onUpdate: (_) {},
        onRevoke: (_) {},
        onGrant: (_) {},
        onOpenDownloads: () => downloadsOpenedCount++,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text('MacBook Pro'));
      await tester.pumpAndSettle();

      expect(find.text('Download Conclave Workspace'), findsNWidgets(2));
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
                    navigation: StudioNavigation.hosts(),
                    workspaces: [initialWorkspace],
                    workers: [],
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
      expect(openedExternalUri, Uri.parse('https://conclaveax.com/how-it-works/'));
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
        final agent = StudioAgent(
          id: 'ws-test',
          name: 'Target Machine',
          hostname: 'host-1',
          status: 'online',
          version: '1.0.0',
          pluginCount: 0,
          workerCount: 0,
          activeTaskCount: 0,
          os: os,
          architecture: arch,
          appVersion: '1.0.0',
        );

        await tester.pumpWidget(scaffold(WorkspacesPage(
          workspaces: [agent],
          workers: const [],
          onAdd: () {},
          onRename: (_) {},
          onUpdate: (_) {},
          onRevoke: (_) {},
          onGrant: (_) {},
        )));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Target Machine'));
        await tester.pumpAndSettle();

        expect(find.text('Machine: $expectedLabel'), findsOneWidget);
      }
    });

    test('Re-enrollment refreshes machine facts while preserving logical entity',
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
