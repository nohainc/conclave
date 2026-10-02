import 'studio_data.dart';
import 'studio_models.dart';

/// Focused Cloud-backed stores. The API remains the source of truth.
class StudioStore {
  StudioStore(this.dataSource)
      : auth = AuthStore(dataSource),
        projects = ProjectStore(dataSource),
        workspaces = WorkspaceStore(dataSource),
        runs = RunStore(dataSource);

  final StudioDataSource dataSource;
  final AuthStore auth;
  final WorkspaceStore workspaces;
  final ProjectStore projects;
  final RunStore runs;

  Future<StudioSnapshot> reload(
      {String? projectId, String? workspaceId}) async {
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
}

class RunStore {
  RunStore(this.source);
  final StudioDataSource source;
  StudioRun? current;

  void replace(StudioRun? value) => current = value;

  Future<void> control(String runId, String command) =>
      source.controlRun(runId, command);
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
