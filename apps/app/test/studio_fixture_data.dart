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
  Future<StudioSnapshot> loadSnapshot(
          {String? projectId, String? workspaceId}) async =>
      studioFixtureSnapshot();

  @override
  Future<void> controlRun(String runId, String command) async {}

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
  }) async {}

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
