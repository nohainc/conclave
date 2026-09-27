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
        accounts = AccountStore(dataSource);

  final StudioDataSource dataSource;
  final AuthStore auth;
  final WorkspaceStore workspaces;
  final ProjectStore projects;
  final ChatStore chats;
  final RunStore runs;
  final AccountStore accounts;

  Future<StudioSnapshot> reload(
      {String? projectId, String? workspaceId}) async {
    final snapshot = await dataSource.loadReadModels(
        projectId: projectId, workspaceId: workspaceId);
    auth.replace(snapshot.viewer);
    workspaces.replace(snapshot.workspaces);
    projects.replace(snapshot.projects);
    chats.replace(snapshot.allChats);
    runs.replace(snapshot.run);
    accounts.replace(snapshot.accounts);
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

  void replace(List<StudioWorkspace> value) => items = List.unmodifiable(value);

  Future<List<StudioWorkspace>> list() async {
    final value = await source.loadWorkspaces();
    replace(value);
    return value;
  }

  Future<StudioWorkspaceEnrollment> createEnrollment(String workspaceId) =>
      source.createWorkspaceEnrollment(workspaceId: workspaceId);

  Future<void> revoke(String workspaceId) =>
      source.revokeWorkspace(workspaceId: workspaceId);

  Future<void> update(String workspaceId, String name) async {
    final updated =
        await source.updateWorkspace(workspaceId: workspaceId, name: name);
    replace(items
        .map((workspace) => workspace.id == workspaceId ? updated : workspace)
        .toList());
  }

  Future<void> announceUpdate(String workspaceId, String runtimeId,
          {String? channel, String? version}) =>
      source.announceWorkspaceUpdate(
          workspaceId: workspaceId,
          runtimeId: runtimeId,
          channel: channel,
          version: version);
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
