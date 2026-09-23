import 'package:conclave_app/src/studio/studio_data.dart';
import 'package:conclave_app/src/studio/studio_models.dart';

import 'studio_fixture_snapshot.dart';

/// Test-only fixture source. Production Studio always uses StudioApiClient.
class StudioFixtureDataSource implements StudioDataSource {
  const StudioFixtureDataSource({this.authenticated = true});

  final bool authenticated;

  @override
  void setActiveWorkspace(String? workspaceId) {}

  @override
  Future<StudioSession> loadSession() async =>
      StudioSession(authenticated: authenticated);

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
  Future<StudioProject> createProject(
          {required String name,
          String? description,
          String? repository,
          String? instructions,
          String? defaultExecutionPolicy}) async =>
      StudioProject(
        id: 'project-created',
        name: name,
        repository: '',
        branch: '',
        activeGoals: 0,
        lastActivity: 'Just now',
      );

  @override
  Future<StudioProject> updateProject({
    required String projectId,
    String? name,
    String? description,
    String? repository,
    String? instructions,
    String? defaultExecutionPolicy,
  }) async {
    final project = studioFixtureSnapshot()
        .projects
        .where((item) => item.id == projectId)
        .firstOrNull;
    return StudioProject(
      id: projectId,
      name: name ?? project?.name ?? 'Updated project',
      repository: repository ?? project?.repository ?? '',
      branch: project?.branch ?? '',
      activeGoals: project?.activeGoals ?? 0,
      lastActivity: 'Just now',
      description: description ?? project?.description ?? '',
    );
  }

  @override
  Future<void> archiveProject({required String projectId}) async {}

  @override
  Future<void> deleteProject({required String projectId}) async {}

  @override
  Future<StudioAccountSecurity> loadAccountSecurity() async =>
      const StudioAccountSecurity(
        accounts: [
          StudioAuthAccount(
              id: 'account-github', providerId: 'github', accountId: 'gh-1'),
        ],
        sessions: [
          StudioAuthSession(
            token: 'fixture-session-token',
            createdAt: '2026-09-23T10:00:00Z',
            expiresAt: '2026-10-07T10:00:00Z',
            userAgent: 'Fixture browser',
          ),
        ],
        passkeys: [
          StudioPasskey(
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
  Future<void> revokeAccountSession(String token) async {}

  @override
  Future<Uri> beginAccountLink(String provider, Uri returnTo) async =>
      Uri.parse('https://accounts.example.test/link/$provider');

  @override
  Future<List<StudioWorkspace>> loadWorkspaces() async => const [
        StudioWorkspace(
          id: 'workspace-fixture',
          name: 'Fixture Workspace',
          slug: 'fixture-workspace',
          status: 'active',
          role: 'owner',
        ),
      ];

  @override
  Future<List<StudioProject>> loadProjects() async =>
      studioFixtureSnapshot().projects;

  @override
  Future<List<StudioAgent>> loadHosts({required String workspaceId}) async =>
      studioFixtureSnapshot().agents;

  @override
  Future<List<StudioWorker>> loadWorkers({required String workspaceId}) async =>
      studioFixtureSnapshot().workers;

  @override
  Future<List<StudioCredentialProfile>> loadCredentialProfiles(
          {required String workspaceId}) async =>
      studioFixtureSnapshot().accounts;

  @override
  Future<StudioWorkspace> updateWorkspace({
    required String workspaceId,
    required String name,
  }) async =>
      StudioWorkspace(
        id: workspaceId,
        name: name,
        slug: name.toLowerCase().replaceAll(' ', '-'),
        status: 'active',
        role: 'owner',
      );

  @override
  Future<List<StudioWorkspaceMember>> loadWorkspaceMembers(
          {required String workspaceId}) async =>
      const [
        StudioWorkspaceMember(
          userId: 'user-1',
          displayName: 'User One',
          email: 'user@example.test',
          role: 'owner',
          status: 'active',
          createdAt: 'Today',
        ),
      ];

  @override
  Future<List<StudioWorkspaceInvitation>> loadWorkspaceInvitations(
          {required String workspaceId}) async =>
      const [];

  @override
  Future<List<StudioAuditEntry>> loadWorkspaceAudit(
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
  Future<StudioSnapshot> loadReadModels(
          {String? projectId, String? workspaceId}) async =>
      studioFixtureSnapshot();

  @override
  Future<StudioSnapshot> loadSnapshot(
          {String? projectId, String? workspaceId}) async =>
      studioFixtureSnapshot();

  @override
  Future<void> controlRun(String runId, String command) async {}

  @override
  Future<void> respondToRunPrompt(String runId, String response) async {}

  @override
  Future<void> createGoal({
    required String projectId,
    required String objective,
    required String revision,
  }) async {}

  @override
  Future<StudioChatMessage> sendChatMessage({
    required String projectId,
    required String chatId,
    required String text,
  }) async {
    return StudioChatMessage(
      id: 'msg-${DateTime.now().millisecondsSinceEpoch}',
      sender: StudioMessageSender.user,
      text: text,
      timestamp: 'Just now',
    );
  }

  @override
  Future<StudioChat> createChat({
    required String projectId,
    required String title,
  }) async {
    return StudioChat(
      id: 'chat-${DateTime.now().millisecondsSinceEpoch}',
      projectId: projectId,
      title: title,
      lastActivity: 'Just now',
      messages: [],
    );
  }

  @override
  Future<void> setWorkerEnabled({
    required String workspaceId,
    required String workerId,
    required bool enabled,
    String? hostId,
  }) async {}

  @override
  Future<StudioCredentialProfile> createCredentialProfile({
    required String workspaceId,
    required String displayName,
    required String workerId,
    required String authType,
    required String ownerType,
    required String sharingPolicy,
    String? hostId,
  }) async =>
      StudioCredentialProfile(
        id: 'account-created',
        displayName: displayName,
        owner: ownerType == 'workspace' ? 'Workspace' : 'You',
        worker: workerId,
        host: hostId ?? 'Cloud',
        sharing: sharingPolicy,
        status: authType == 'none' ? 'ready' : 'setup_required',
      );

  @override
  Future<void> requestCredentialSetup({
    required String workspaceId,
    required String profileId,
    String action = 'reauthenticate',
  }) async {}

  @override
  Future<void> revokeCredentialProfile({
    required String workspaceId,
    required String profileId,
  }) async {}

  @override
  Future<void> revokeAgent({
    required String workspaceId,
    required String agentId,
  }) async {}

  @override
  Future<void> updateHost({
    required String workspaceId,
    required String hostId,
    String? name,
    String? channel,
  }) async {}

  @override
  Future<void> bindHostWorkspace({
    required String workspaceId,
    required String hostId,
  }) async {}

  @override
  Future<void> announceAgentUpdate({
    required String workspaceId,
    required String agentId,
    String? channel,
    String? version,
  }) async {}

  @override
  Future<StudioHostEnrollment> createHostEnrollment({
    required String workspaceId,
    int expiresHours = 24,
  }) async {
    return StudioHostEnrollment(
      id: 'enrollment-fixture',
      token: 'conclave_enroll_fixture',
      workspaceId: workspaceId,
      expiresAt: 'Tomorrow',
    );
  }

  @override
  Future<void> saveWorker({
    required String workspaceId,
    String? workerId,
    required String name,
    required String agentId,
    required String workerCatalogId,
    required List<String> roles,
    required List<String> capabilities,
    required bool enabled,
    String workerVersionPolicy = 'latest',
    Map<String, dynamic> config = const {},
    String sessionPolicy = 'stateless',
    int concurrencyLimit = 1,
    String billingMode = 'local_compute',
    String independenceKey = '',
    Map<String, dynamic> costMetadata = const {},
  }) async {}
}

/// Stateful fixture used by the empty-workspace onboarding test. It mirrors
/// the production API flow closely enough to verify the shell, project
/// creation, chat creation, and subsequent read-model refresh together.
class EmptyWorkspaceFixtureDataSource extends StudioFixtureDataSource {
  EmptyWorkspaceFixtureDataSource() : super();

  bool hasProject = false;
  bool hasChat = false;

  @override
  Future<StudioSnapshot> loadReadModels(
      {String? projectId, String? workspaceId}) async {
    return _snapshot();
  }

  @override
  Future<StudioSnapshot> loadSnapshot(
      {String? projectId, String? workspaceId}) async {
    return _snapshot();
  }

  @override
  Future<StudioProject> createProject(
      {required String name,
      String? description,
      String? repository,
      String? instructions,
      String? defaultExecutionPolicy}) async {
    hasProject = true;
    return StudioProject(
      id: 'project-created',
      name: name,
      repository: '',
      branch: '',
      activeGoals: 0,
      lastActivity: 'Just now',
    );
  }

  @override
  Future<StudioChat> createChat({
    required String projectId,
    required String title,
  }) async {
    hasChat = true;
    return super.createChat(projectId: projectId, title: title);
  }

  StudioSnapshot _snapshot() {
    final project = StudioProject(
      id: 'project-created',
      name: 'My first project',
      repository: '',
      branch: '',
      activeGoals: 0,
      lastActivity: 'Just now',
      chats: hasChat
          ? const [
              StudioChat(
                id: 'chat-created',
                projectId: 'project-created',
                title: 'First chat',
                lastActivity: 'Just now',
                messages: [],
              ),
            ]
          : const [],
    );
    return studioFixtureSnapshot().copyWith(
      projects: hasProject ? [project] : const [],
      activeChatId: hasChat ? 'chat-created' : null,
    );
  }
}
