import 'package:conclave_app/src/ax/ax_data.dart';
import 'package:conclave_app/src/ax/ax_models.dart';

import 'ax_fixture_snapshot.dart';

/// Test-only fixture source. Production Ax always uses AxApiClient.
class AxFixtureDataSource implements AxDataSource {
  const AxFixtureDataSource({this.authenticated = true});

  final bool authenticated;

  @override
  Future<String> createWorkRequest({
    required String workstreamId,
    required String workflowId,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
  }) async =>
      throw UnimplementedError('Work Request fixture is not configured');

  @override
  Future<List<String>> validateWorkRequestEligibility({
    required String workstreamId,
    required String workflowId,
    List<Map<String, dynamic>> attachments = const [],
  }) async =>
      const [];

  @override
  Future<AxWorkRequestStatus> loadWorkRequest({
    required String workRequestId,
  }) async =>
      throw UnimplementedError('Work Request fixture is not configured');

  @override
  Future<List<AxWorkRequest>> loadWorkstreamWorkRequests({
    required String workstreamId,
    bool activeOnly = false,
  }) async =>
      const [];

  @override
  Future<void> retryWorkRequestStep({
    required String workRequestId,
    required String stepKind,
    String? sessionStrategy,
  }) async {}

  @override
  Future<void> cancelWorkRequest({required String workRequestId}) async {}

  @override
  Future<AxSession> loadSession() async =>
      AxSession(authenticated: authenticated);

  @override
  Future<void> logout() async {}

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> signUpWithEmail({
    required String name,
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> requestPasswordReset({required String email}) async {}

  @override
  Future<void> resetPassword({
    required String token,
    required String password,
  }) async {}

  @override
  Future<AxProject> createProject(
          {required String name,
          String? description,
          String? instructions}) async =>
      AxProject(
        id: 'project-created',
        name: name,
        branch: '',
        lastActivity: 'Just now',
      );

  @override
  Future<AxProject> updateProject({
    required String projectId,
    String? name,
    String? description,
    String? instructions,
    Map<String, dynamic>? settings,
  }) async {
    final project = axFixtureSnapshot()
        .projects
        .where((item) => item.id == projectId)
        .firstOrNull;
    return AxProject(
      id: projectId,
      name: name ?? project?.name ?? 'Updated project',
      branch: project?.branch ?? '',
      lastActivity: 'Just now',
      description: description ?? project?.description ?? '',
      instructions: instructions ?? project?.instructions ?? '',
      settings: settings ?? project?.settings ?? const {},
    );
  }

  @override
  Future<void> archiveProject({required String projectId}) async {}

  @override
  Future<void> deleteProject({required String projectId}) async {}

  @override
  @override
  Future<List<AxDiscussionMessage>> loadDiscussionMessages({
    required String workstreamId,
  }) async =>
      const [];

  @override
  Future<AxDiscussionMessage> sendDiscussionMessage({
    required String workstreamId,
    required String text,
    List<String> references = const [],
  }) async =>
      AxDiscussionMessage(
        id: 'msg-${DateTime.now().microsecondsSinceEpoch}',
        workstreamId: workstreamId,
        authorUserId: 'user-owner',
        authorName: 'Vitalii',
        body: text,
        references: references,
        createdAt: DateTime.now().toIso8601String(),
        isMe: true,
      );

  @override
  Future<AxDiscussionMessage> editDiscussionMessage({
    required String messageId,
    required String text,
    List<String> references = const [],
  }) async =>
      AxDiscussionMessage(
        id: messageId,
        workstreamId: 'workstream-1',
        authorUserId: 'user-owner',
        authorName: 'Vitalii',
        body: text,
        references: references,
        editedAt: DateTime.now().toIso8601String(),
        createdAt: DateTime.now().toIso8601String(),
        isMe: true,
      );

  @override
  Future<List<AxProjectMember>> loadProjectMembers({
    required String projectId,
  }) async =>
      const [
        AxProjectMember(
          userId: 'user-owner',
          displayName: 'Vitalii',
          email: 'owner@example.com',
          role: 'owner',
          createdAt: 'today',
        ),
      ];

  @override
  Future<List<AxProjectInvitation>> loadProjectInvitations({
    required String projectId,
  }) async =>
      const [];

  @override
  Future<List<AxAuditEntry>> loadProjectAudit({
    required String projectId,
  }) async =>
      const [];

  @override
  Future<void> inviteProjectMember({
    required String projectId,
    required String email,
    required String role,
  }) async {}

  @override
  Future<void> changeProjectMemberRole({
    required String projectId,
    required String userId,
    required String role,
  }) async {}

  @override
  Future<void> removeProjectMember({
    required String projectId,
    required String userId,
  }) async {}

  @override
  Future<void> expireProjectInvitation({
    required String projectId,
    required String invitationId,
  }) async {}

  @override
  Future<void> revokeWorkspaceProjectGrant({
    required String grantId,
  }) async {}

  @override
  Future<AxAccountSecurity> loadAccountSecurity() async =>
      const AxAccountSecurity(
        accounts: [
          AxAuthAccount(
              id: 'account-github', providerId: 'github', accountId: 'gh-1'),
        ],
        sessions: [
          AxAuthSession(
            token: 'fixture-session-token',
            createdAt: '2026-09-23T10:00:00Z',
            expiresAt: '2026-10-07T10:00:00Z',
            userAgent: 'Fixture browser',
          ),
        ],
        passkeys: [
          AxPasskey(
              id: 'passkey-1', name: 'MacBook Touch ID', createdAt: 'today'),
        ],
      );

  @override
  Future<void> registerPasskey(String name) async {}

  @override
  Future<void> deletePasskey(String id) async {}

  @override
  Future<void> signInWithPasskey() async {}

  @override
  Future<void> approveDesktopAuthIntent({required String intentId}) async {}

  @override
  Future<AxDesktopAuthIntentStatus> loadDesktopAuthIntentStatus(
          {required String intentId}) async =>
      const AxDesktopAuthIntentStatus(
        status: 'pending',
        clientName: 'Conclave Workspace',
        audience: 'conclave.desktop.management',
      );

  @override
  Future<void> denyDesktopAuthIntent({required String intentId}) async {}

  @override
  Future<void> revokeAccountSession(String token) async {}

  @override
  Future<Uri> beginAccountLink(String provider, Uri returnTo) async =>
      Uri.parse('https://accounts.example.test/link/$provider');

  @override
  Future<List<AxWorkspace>> loadWorkspaces() async => const [
        AxWorkspace(
          id: 'workspace-fixture',
          name: 'Fixture Workspace',
          slug: 'fixture-workspace',
          status: 'active',
          role: 'owner',
        ),
      ];

  @override
  Future<List<AxProject>> loadProjects({bool includeArchived = false}) async =>
      axFixtureSnapshot().projects;

  @override
  Future<List<Map<String, dynamic>>> loadProjectWorkspaces({
    required String projectId,
  }) async =>
      const [];

  @override
  Future<void> requestProjectWorkspace({
    required String projectId,
    required String workspaceId,
  }) async {}

  @override
  Future<List<AxWorkstream>> loadProjectWorkstreams({
    required String projectId,
  }) async =>
      axFixtureSnapshot()
          .projects
          .where((project) => project.id == projectId)
          .expand((project) => project.workstreams)
          .toList();

  @override
  Future<AxWorkstream> createWorkstream({
    required String projectId,
    required String name,
  }) async =>
      AxWorkstream(
        id: 'workstream-created',
        projectId: projectId,
        name: name,
        lead: 'You',
        status: 'active',
        brief: '',
        primaryWorkspace: 'Not selected',
        queueStatus: 'Idle',
      );

  @override
  Future<AxWorkstream> updateWorkstream({
    required String workstreamId,
    String? name,
    String? status,
    Map<String, dynamic>? workConfig,
  }) async =>
      AxWorkstream(
        id: workstreamId,
        projectId: 'project-1',
        name: name ?? 'Updated Workstream',
        lead: 'You',
        status: status ?? 'active',
        brief: '',
        primaryWorkspace: 'Not selected',
        queueStatus: 'Idle',
        workConfig: workConfig ??
            const {
              'defaultWorkflowId': 'full_cycle',
              'bindings': <String, dynamic>{},
            },
      );

  @override
  Future<void> deleteWorkstream({required String workstreamId}) async {}

  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async => const [];

  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async =>
      const [];

  @override
  Future<AxWorkspace> updateWorkspace({
    required String workspaceId,
    required String name,
  }) async =>
      AxWorkspace(
        id: workspaceId,
        name: name,
        slug: name.toLowerCase().replaceAll(' ', '-'),
        status: 'active',
        role: 'owner',
      );

  @override
  Future<List<AxWorkspaceMember>> loadWorkspaceMembers(
          {required String workspaceId}) async =>
      const [
        AxWorkspaceMember(
          userId: 'user-1',
          displayName: 'User One',
          email: 'user@example.test',
          role: 'owner',
          status: 'active',
          createdAt: 'Today',
        ),
      ];

  @override
  Future<List<AxWorkspaceInvitation>> loadWorkspaceInvitations(
          {required String workspaceId}) async =>
      const [];

  @override
  Future<List<AxAuditEntry>> loadWorkspaceAudit(
          {required String workspaceId}) async =>
      const [];

  @override
  Future<void> inviteWorkspaceMember({
    required String workspaceId,
    required String email,
    required String role,
  }) async {}

  @override
  Future<void> changeWorkspaceMemberRole({
    required String workspaceId,
    required String userId,
    required String role,
  }) async {}

  @override
  Future<void> setWorkspaceMemberStatus({
    required String workspaceId,
    required String userId,
    required String status,
  }) async {}

  @override
  Future<void> expireWorkspaceInvitation({
    required String workspaceId,
    required String invitationId,
  }) async {}

  @override
  Future<AxSnapshot> loadReadModels(
          {String? projectId, String? workspaceId}) async =>
      axFixtureSnapshot();

  @override
  Future<void> controlRun(String runId, String command) async {}

  @override
  Future<void> respondToRunPrompt(String runId, String response) async {}

  @override
  Future<void> revokeWorkspace({required String workspaceId}) async {}
}

/// Stateful fixture used by the empty-workspace onboarding test. It mirrors
/// the production API flow closely enough to verify the shell, project
/// creation and subsequent data refresh together.
class EmptyWorkspaceFixtureDataSource extends AxFixtureDataSource {
  EmptyWorkspaceFixtureDataSource() : super();

  bool hasProject = false;

  @override
  Future<AxSnapshot> loadReadModels(
      {String? projectId, String? workspaceId}) async {
    return _snapshot();
  }

  @override
  Future<AxProject> createProject(
      {required String name, String? description, String? instructions}) async {
    hasProject = true;
    return AxProject(
      id: 'project-created',
      name: name,
      branch: '',
      lastActivity: 'Just now',
    );
  }

  AxSnapshot _snapshot() {
    const project = AxProject(
      id: 'project-created',
      name: 'My first project',
      branch: '',
      lastActivity: 'Just now',
    );
    return axFixtureSnapshot().copyWith(
      projects: hasProject ? [project] : const [],
    );
  }
}
