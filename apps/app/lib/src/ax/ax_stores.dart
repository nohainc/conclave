import 'ax_data.dart';
import 'ax_models.dart';

/// Focused Cloud-backed stores. The API remains the source of truth.
class AxStore {
  AxStore(this.dataSource)
      : auth = AuthStore(dataSource),
        projects = ProjectStore(dataSource),
        workspaces = WorkspaceStore(dataSource),
        runs = RunStore(dataSource);

  final AxDataSource dataSource;
  final AuthStore auth;
  final WorkspaceStore workspaces;
  final ProjectStore projects;
  final RunStore runs;

  Future<AxSnapshot> reload({String? projectId, String? workspaceId}) async {
    final snapshot = await dataSource.loadReadModels(
        projectId: projectId, workspaceId: workspaceId);
    auth.replace(snapshot.viewer);
    workspaces.replace(snapshot.workspaces);
    projects.replace(snapshot.projects);
    runs.replace(snapshot.run);
    return snapshot;
  }
}

class ProjectStore {
  ProjectStore(this.source);
  final AxDataSource source;
  List<AxProject> items = const [];

  void replace(List<AxProject> value) => items = List.unmodifiable(value);

  Future<List<AxProject>> refresh() async {
    final value = await source.loadProjects();
    replace(value);
    return value;
  }
}

class WorkspaceStore {
  WorkspaceStore(this.source);
  final AxDataSource source;
  List<AxWorkspace> items = const [];

  void replace(List<AxWorkspace> value) => items = List.unmodifiable(value);

  Future<List<AxWorkspace>> list() async {
    final value = await source.loadWorkspaces();
    replace(value);
    return value;
  }

  Future<void> revoke(String workspaceId) =>
      source.revokeWorkspace(workspaceId: workspaceId);

  Future<void> update(String workspaceId, String name) async {
    final updated =
        await source.updateWorkspace(workspaceId: workspaceId, name: name);
    replace(items
        .map((workspace) => workspace.id == workspaceId ? updated : workspace)
        .toList());
  }
}

class RunStore {
  RunStore(this.source);
  final AxDataSource source;
  AxRun? current;

  void replace(AxRun? value) => current = value;

  Future<void> control(String runId, String command) =>
      source.controlRun(runId, command);
}

class AuthStore {
  AuthStore(this.source);

  final AxDataSource source;
  AxSession? session;
  AxViewer? viewer;

  void replace(AxViewer? value) {
    if (value != null) viewer = value;
  }

  Future<AxSession> load() async {
    final value = await source.loadSession();
    session = value;
    viewer = value.viewer;
    return value;
  }

  Future<void> logout() async {
    await source.logout();
    session = const AxSession(authenticated: false);
    viewer = null;
  }
}
