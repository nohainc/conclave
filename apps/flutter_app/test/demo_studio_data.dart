import 'package:conclave_app/src/studio/studio_data.dart';
import 'package:conclave_app/src/studio/studio_models.dart';

import 'demo_snapshot.dart';

/// Test-only fixture source. Production Studio always uses StudioApiClient.
class DemoStudioDataSource implements StudioDataSource {
  const DemoStudioDataSource();

  @override
  Future<StudioSession> loadSession() async => const StudioSession(
        authenticated: true,
      );

  @override
  Future<void> logout() async {}

  @override
  Future<List<StudioWorkspace>> loadWorkspaces() async => const [
        StudioWorkspace(
          id: 'workspace-demo',
          name: 'Demo Workspace',
          slug: 'demo-workspace',
          status: 'active',
          role: 'owner',
        ),
      ];

  @override
  Future<StudioSnapshot> loadSnapshot(
          {String? projectId, String? workspaceId}) async =>
      demoStudioSnapshot();

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
  Future<StudioAgentEnrollment> createAgentEnrollment({
    required String workspaceId,
    int expiresHours = 24,
  }) async {
    return StudioAgentEnrollment(
      id: 'enrollment-demo',
      token: 'conclave_enroll_demo',
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
    required String pluginId,
    required List<String> roles,
    required List<String> capabilities,
    required bool enabled,
    String pluginVersionPolicy = 'latest',
    Map<String, dynamic> config = const {},
    String sessionPolicy = 'stateless',
    int concurrencyLimit = 1,
    String billingMode = 'local_compute',
    String independenceKey = '',
    Map<String, dynamic> costMetadata = const {},
  }) async {}
}
