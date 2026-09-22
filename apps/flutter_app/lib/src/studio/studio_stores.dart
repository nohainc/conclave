import 'studio_data.dart';
import 'studio_models.dart';

/// Focused Cloud-backed stores. The API remains the source of truth.
class StudioStore {
  StudioStore(this.dataSource)
      : projects = ProjectStore(dataSource),
        workspaces = WorkspaceStore(dataSource),
        chats = ChatStore(dataSource),
        runs = RunStore(dataSource),
        agents = AgentStore(dataSource),
        workers = WorkerStore(dataSource),
        plugins = PluginStore(dataSource),
        usage = UsageStore(dataSource);

  final StudioDataSource dataSource;
  final WorkspaceStore workspaces;
  final ProjectStore projects;
  final ChatStore chats;
  final RunStore runs;
  final AgentStore agents;
  final WorkerStore workers;
  final PluginStore plugins;
  final UsageStore usage;

  Future<StudioSnapshot> reload({String? projectId, String? workspaceId}) =>
      dataSource.loadSnapshot(
          projectId: projectId, workspaceId: workspaceId);
}

class ProjectStore {
  const ProjectStore(this.source);
  final StudioDataSource source;
}

class WorkspaceStore {
  const WorkspaceStore(this.source);
  final StudioDataSource source;

  Future<List<StudioWorkspace>> list() => source.loadWorkspaces();
}

class ChatStore {
  const ChatStore(this.source);
  final StudioDataSource source;
  Future<StudioChat> create(String projectId, String title) =>
      source.createChat(projectId: projectId, title: title);
  Future<StudioChatMessage> send(
          String projectId, String chatId, String text) =>
      source.sendChatMessage(projectId: projectId, chatId: chatId, text: text);
}

class RunStore {
  const RunStore(this.source);
  final StudioDataSource source;
  Future<void> control(String runId, String command) =>
      source.controlRun(runId, command);
}

class AgentStore {
  const AgentStore(this.source);
  final StudioDataSource source;

  Future<void> revoke(String workspaceId, String agentId) =>
      source.revokeAgent(workspaceId: workspaceId, agentId: agentId);
}

class WorkerStore {
  const WorkerStore(this.source);
  final StudioDataSource source;

  Future<void> setEnabled(String workspaceId, String workerId, bool enabled) =>
      source.setWorkerEnabled(
          workspaceId: workspaceId, workerId: workerId, enabled: enabled);

  Future<void> save({
    required String workspaceId,
    String? workerId,
    required String name,
    required String agentId,
    required String pluginId,
    required List<String> roles,
    required List<String> capabilities,
    required bool enabled,
  }) =>
      source.saveWorker(
          workspaceId: workspaceId,
          workerId: workerId,
          name: name,
          agentId: agentId,
          pluginId: pluginId,
          roles: roles,
          capabilities: capabilities,
          enabled: enabled);
}

class PluginStore {
  const PluginStore(this.source);
  final StudioDataSource source;
}

class UsageStore {
  const UsageStore(this.source);
  final StudioDataSource source;
}
