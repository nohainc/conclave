import 'studio_data.dart';
import 'studio_models.dart';

/// Focused Cloud-backed stores. The API remains the source of truth.
class StudioStore {
  StudioStore(this.dataSource)
      : auth = AuthStore(dataSource),
        projects = ProjectStore(dataSource),
        workspaces = WorkspaceStore(dataSource),
        chats = ChatStore(dataSource),
        runs = RunStore(dataSource),
        agents = AgentStore(dataSource),
        workers = WorkerStore(dataSource),
        plugins = PluginStore(dataSource),
        accounts = AccountStore(dataSource),
        usage = UsageStore(dataSource);

  final StudioDataSource dataSource;
  final AuthStore auth;
  final WorkspaceStore workspaces;
  final ProjectStore projects;
  final ChatStore chats;
  final RunStore runs;
  final AgentStore agents;
  final WorkerStore workers;
  final PluginStore plugins;
  final AccountStore accounts;
  final UsageStore usage;

  Future<StudioSnapshot> reload(
      {String? projectId, String? workspaceId}) async {
    final snapshot = await dataSource.loadReadModels(
        projectId: projectId, workspaceId: workspaceId);
    auth.replace(snapshot.viewer);
    workspaces.replace(snapshot.workspaceId);
    projects.replace(snapshot.projects);
    chats.replace(snapshot.allChats);
    runs.replace(snapshot.run);
    agents.replace(snapshot.agents);
    workers.replace(snapshot.workers);
    plugins.replace(snapshot.plugins);
    accounts.replace(snapshot.accounts);
    usage.replace(snapshot.run);
    return snapshot;
  }
}

class ProjectStore {
  ProjectStore(this.source);
  final StudioDataSource source;
  List<StudioProject> items = const [];

  void replace(List<StudioProject> value) => items = List.unmodifiable(value);

  Future<List<StudioProject>> refresh() async {
    final value = await source.loadProjects();
    replace(value);
    return value;
  }
}

class WorkspaceStore {
  WorkspaceStore(this.source);
  final StudioDataSource source;
  List<StudioWorkspace> items = const [];
  String? activeWorkspaceId;

  Future<List<StudioWorkspace>> list() async {
    final value = await source.loadWorkspaces();
    items = List.unmodifiable(value);
    activeWorkspaceId ??= value.firstOrNull?.id;
    return value;
  }

  Future<StudioWorkspace> create({required String name, String? slug}) async {
    final workspace = await source.createWorkspace(name: name, slug: slug);
    items = List.unmodifiable([...items, workspace]);
    return workspace;
  }

  void replace(String? activeWorkspaceId) {
    this.activeWorkspaceId = activeWorkspaceId;
    source.setActiveWorkspace(activeWorkspaceId);
  }
}

class ChatStore {
  ChatStore(this.source);
  final StudioDataSource source;
  List<StudioChat> items = const [];

  void replace(List<StudioChat> value) => items = List.unmodifiable(value);

  Future<StudioChat> create(String projectId, String title) =>
      source.createChat(projectId: projectId, title: title);
  Future<StudioChatMessage> send(
          String projectId, String chatId, String text) =>
      source.sendChatMessage(projectId: projectId, chatId: chatId, text: text);
}

class RunStore {
  RunStore(this.source);
  final StudioDataSource source;
  StudioRun? current;

  void replace(StudioRun? value) => current = value;

  Future<void> control(String runId, String command) =>
      source.controlRun(runId, command);
}

class AgentStore {
  AgentStore(this.source);
  final StudioDataSource source;
  List<StudioAgent> items = const [];

  Future<StudioHostEnrollment> createEnrollment(String workspaceId) =>
      source.createHostEnrollment(workspaceId: workspaceId);

  void replace(List<StudioAgent> value) => items = List.unmodifiable(value);

  Future<List<StudioAgent>> refresh(String workspaceId) async {
    final value = await source.loadHosts(workspaceId: workspaceId);
    replace(value);
    return value;
  }

  Future<void> revoke(String workspaceId, String agentId) =>
      source.revokeAgent(workspaceId: workspaceId, agentId: agentId);

  Future<void> announceUpdate(String workspaceId, String agentId,
          {String? channel, String? version}) =>
      source.announceAgentUpdate(
          workspaceId: workspaceId,
          agentId: agentId,
          channel: channel,
          version: version);

  Future<void> updateHost(String workspaceId, String hostId,
          {String? name, String? channel}) =>
      source.updateHost(
          workspaceId: workspaceId,
          hostId: hostId,
          name: name,
          channel: channel);

  Future<void> bindWorkspace(String workspaceId, String hostId) =>
      source.bindHostWorkspace(workspaceId: workspaceId, hostId: hostId);
}

class WorkerStore {
  WorkerStore(this.source);
  final StudioDataSource source;
  List<StudioWorker> items = const [];

  void replace(List<StudioWorker> value) => items = List.unmodifiable(value);

  Future<List<StudioWorker>> refresh(String workspaceId) async {
    final value = await source.loadWorkers(workspaceId: workspaceId);
    replace(value);
    return value;
  }

  Future<void> setEnabled(String workspaceId, String workerId, bool enabled,
          {String? hostId}) =>
      source.setWorkerEnabled(
          workspaceId: workspaceId,
          workerId: workerId,
          enabled: enabled,
          hostId: hostId);

  Future<void> save({
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
  }) =>
      source.saveWorker(
          workspaceId: workspaceId,
          workerId: workerId,
          name: name,
          agentId: agentId,
          workerCatalogId: workerCatalogId,
          roles: roles,
          capabilities: capabilities,
          enabled: enabled,
          workerVersionPolicy: workerVersionPolicy,
          config: config,
          sessionPolicy: sessionPolicy,
          concurrencyLimit: concurrencyLimit,
          billingMode: billingMode,
          independenceKey: independenceKey,
          costMetadata: costMetadata);
}

class PluginStore {
  PluginStore(this.source);
  final StudioDataSource source;
  List<StudioPlugin> items = const [];

  void replace(List<StudioPlugin> value) => items = List.unmodifiable(value);
}

class AccountStore {
  AccountStore(this.source);
  final StudioDataSource source;
  List<StudioCredentialProfile> items = const [];

  void replace(List<StudioCredentialProfile> value) =>
      items = List.unmodifiable(value);

  Future<List<StudioCredentialProfile>> refresh(String workspaceId) async {
    final value = await source.loadCredentialProfiles(workspaceId: workspaceId);
    replace(value);
    return value;
  }
}

class UsageStore {
  UsageStore(this.source);
  final StudioDataSource source;
  int tokens = 0;
  int costMicros = 0;

  void replace(StudioRun? run) {
    tokens = run?.tokens ?? 0;
    costMicros = run?.costMicros ?? 0;
  }
}

class AuthStore {
  AuthStore(this.source);

  final StudioDataSource source;
  StudioSession? session;
  StudioViewer? viewer;

  void replace(StudioViewer? value) {
    if (value != null) viewer = value;
  }

  Future<StudioSession> load() async {
    final value = await source.loadSession();
    session = value;
    viewer = value.viewer;
    return value;
  }

  Future<void> logout() async {
    await source.logout();
    session = const StudioSession(authenticated: false);
    viewer = null;
  }
}
