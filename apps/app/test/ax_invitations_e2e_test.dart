import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_app.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/home/home_page.dart';
import 'package:conclave_app/src/features/projects/projects_pages.dart';
import 'package:conclave_app/src/navigation/ax_browser_navigation.dart';
import 'package:conclave_app/src/platform/platform_services.dart';
import 'ax_fixture_data.dart';
import 'ax_fixture_realtime.dart';

class InvitationsTestNavigation implements AxBrowserNavigation {
  InvitationsTestNavigation(this.current);
  @override
  Uri current;
  final controller = StreamController<Uri>.broadcast(sync: true);
  @override
  Stream<Uri> get changes => controller.stream;
  @override
  Stream<void> get lifecycleChanges => const Stream.empty();

  @override
  void push(Uri uri) {
    current = uri;
    controller.add(uri);
  }

  @override
  void replace(Uri uri) {
    current = uri;
    controller.add(uri);
  }

  @override
  void replaceWithLogin(Uri returnTo) {
    current = Uri(path: '/login');
  }

  @override
  void startSocialLogin(String provider, Uri returnTo) {}
  @override
  void openExternal(Uri uri) {}
  @override
  bool closeCurrentWindow() => false;
  @override
  void dispose() {
    unawaited(controller.close());
  }
}

class InvitationsE2eDataSource extends AxFixtureDataSource {
  InvitationsE2eDataSource({
    this.initialProjects = const [],
    this.initialInvitations = const [],
  }) {
    projects = List.of(initialProjects);
    invitations = List.of(initialInvitations);
  }

  final List<AxProject> initialProjects;
  final List<AxProjectInvitation> initialInvitations;
  late List<AxProject> projects;
  late List<AxProjectInvitation> invitations;

  int acceptCalls = 0;
  int declineCalls = 0;
  int refreshInvitationsCalls = 0;

  @override
  Future<List<AxProject>> loadProjects({bool includeArchived = false}) async =>
      projects;

  @override
  Future<List<AxProjectInvitation>> loadCurrentUserInvitations() async {
    refreshInvitationsCalls++;
    return invitations;
  }

  @override
  Future<void> acceptProjectInvitation({required String invitationId}) async {
    acceptCalls++;
    final invite = invitations.firstWhere((item) => item.id == invitationId);
    invitations.removeWhere((item) => item.id == invitationId);
    projects.add(AxProject(
      id: invite.projectId,
      name: invite.projectName.isNotEmpty ? invite.projectName : 'New Project',
      branch: 'main',
      lastActivity: DateTime.now().toIso8601String(),
      role: invite.role,
    ));
  }

  @override
  Future<void> declineProjectInvitation({required String invitationId}) async {
    declineCalls++;
    invitations.removeWhere((item) => item.id == invitationId);
  }

  @override
  Future<AxProject> loadProject({required String projectId}) async {
    final proj = projects.firstWhere(
      (p) => p.id == projectId,
      orElse: () => AxProject(
        id: projectId,
        name: 'Project $projectId',
        branch: 'main',
        lastActivity: '',
        role: 'collaborator',
      ),
    );
    return proj;
  }

  @override
  Future<List<AxWorkstream>> loadProjectWorkstreams(
          {required String projectId}) async =>
      [];

  @override
  Future<List<AxWorkspace>> loadWorkspaces() async => [];

  @override
  Future<AxSnapshot> loadBootstrapState(
      {String? projectId, String? workspaceId}) async {
    return AxSnapshot(
      projects: projects,
      workspaces: const [],
      tasks: const [],
      findings: const [],
      events: const [],
      artifacts: const [],
    );
  }
}

void main() {
  testWidgets(
      'zero-project user discovers invitation on Welcome screen and opens project on accept without app reload',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const invite = AxProjectInvitation(
      id: 'pinv-hero-1',
      projectId: 'proj-collab',
      projectName: 'Conclave AX Development',
      email: 'ulikossnokia@gmail.com',
      role: 'collaborator',
      status: 'pending',
      invitedByUserName: 'Vitalii Noha',
      invitedByUserEmail: 'vitalii@nohainc.com',
      createdAt: '2026-10-07T12:00:00Z',
    );

    final dataSource = InvitationsE2eDataSource(
      initialProjects: [],
      initialInvitations: [invite],
    );
    final browser = InvitationsTestNavigation(Uri.parse('/'));
    final realtime = TestRealtime();

    await tester.pumpWidget(MaterialApp(
      home: ConclaveAppShell(
        dataSource: dataSource,
        services: const DefaultPlatformServices(),
        browserNavigation: browser,
        realtimeClient: realtime,
      ),
    ));
    await tester.pumpAndSettle();

    // 1. Zero-project recipient with pending invitation renders NewUserHome with Join a Project priority card
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.text('Welcome to Conclave AX'), findsOneWidget);
    expect(find.text('Join a Project'), findsOneWidget);
    expect(find.text('You have 1 invitation.'), findsOneWidget);
    expect(find.text('Conclave AX Development'), findsWidgets);
    expect(find.text('Accept'), findsWidgets);

    // 2. Click Accept invitation
    await tester.tap(find.text('Accept').first);
    await tester.pump();
    await tester.pumpAndSettle();

    // 3. Verify instantaneous navigation into accepted Project without app reload
    expect(dataSource.acceptCalls, 1);
    expect(find.byType(ProjectPage), findsOneWidget);
    expect(find.text('Conclave AX Development'), findsWidgets);
    expect(browser.current.path, '/projects/proj-collab');

    // Drain toast timer
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'online recipient receives invitation via realtime event and updates badge/inbox',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dataSource = InvitationsE2eDataSource(
      initialProjects: [
        const AxProject(
          id: 'proj-1',
          name: 'Existing Project',
          branch: 'main',
          lastActivity: '',
        )
      ],
      initialInvitations: [],
    );
    final browser = InvitationsTestNavigation(Uri.parse('/'));
    final realtime = TestRealtime();

    await tester.pumpWidget(MaterialApp(
      home: ConclaveAppShell(
        dataSource: dataSource,
        services: const DefaultPlatformServices(),
        browserNavigation: browser,
        realtimeClient: realtime,
      ),
    ));
    await tester.pumpAndSettle();

    // Initially no pending invitations
    expect(find.text('Pending invitations (1)'), findsNothing);

    // Vitalii sends invitation -> Cloud fans out realtime event to online recipient
    dataSource.invitations = [
      const AxProjectInvitation(
        id: 'pinv-live-2',
        projectId: 'proj-live',
        projectName: 'Live Shared Project',
        email: 'ulikossnokia@gmail.com',
        role: 'collaborator',
        status: 'pending',
        invitedByUserName: 'Vitalii Noha',
        createdAt: '2026-10-07T12:00:00Z',
      )
    ];

    realtime.emit({
      'type': 'project.updated',
      'projectId': 'proj-live',
      'payload': {'entityId': 'pinv-live-2'},
    });
    await tester.pump();
    await tester.pumpAndSettle();

    // Bell icon badge and sidebar show Pending invitations (1)
    expect(find.text('Pending invitations (1)'), findsWidgets);
    expect(find.textContaining('Live Shared Project'), findsWidgets);
  });
}
