import 'dart:async';
import 'package:flutter/foundation.dart';
import 'sync/persistence/ax_persistent_read_cache.dart';
import '../notifications/notification_models.dart';
import 'ax_data.dart';
import 'ax_models.dart';
import 'sync/ax_project_workstreams.dart';
import 'sync/ax_project_details.dart';
import 'sync/ax_sync_engine.dart';
import 'sync/ax_discussion_cache.dart';
import 'sync/ax_work_history.dart';
import 'sync/ax_work_realtime_sync.dart';
import 'sync/ax_realtime_cache_router.dart';
import 'sync/ax_session_catalogs.dart';
import 'sync/ax_project_workspace_grants.dart';
import 'sync/ax_project_tab_queries.dart';
import 'sync/ax_owned_workspaces.dart';
import 'sync/ax_collaboration_mutations.dart';
import 'sync/ax_lifecycle_sync.dart';

/// Focused Cloud-backed stores. The API remains the source of truth.
class AxStore {
  AxStore(this.dataSource,
      {AxReadCacheBackend? readCacheBackend,
      bool persistReadCache = const bool.fromEnvironment(
          'AX_PERSIST_READ_CACHE',
          defaultValue: true)})
      : _readCacheBackend = readCacheBackend,
        _persistReadCache = persistReadCache,
        auth = AuthStore(dataSource),
        runs = RunStore(dataSource) {
    invitations.addListener(_updateUnreadNotifications);
  }

  final AxReadCacheBackend? _readCacheBackend;
  final bool _persistReadCache;
  late final persistence = AxPersistentReadCache(syncEngine, dataSource,
      backend: _readCacheBackend, enabled: _persistReadCache);
  Future<bool> hydrateReadCache() async {
    final session = auth.session;
    final id = session?.viewer?.id;
    if (session?.authenticated != true ||
        id == null ||
        id.isEmpty ||
        id == '—') {
      return false;
    }
    if (persistence.userId != null && persistence.userId != id) {
      clearServerState();
    }
    return persistence.hydrate(id);
  }

  Future<void> logout() async {
    final clearing = persistence.clearUser();
    clearServerState();
    try {
      await auth.logout();
    } finally {
      await clearing;
    }
  }

  int _sessionGeneration = 0;
  bool _disposed = false;
  AxSnapshot _execution = AxSnapshot.empty();
  final executionChanges = AxViewSignal();
  final lifecycleNotice = ValueNotifier<String?>(null);
  late final lifecycle = AxLifecycleSync(syncEngine,
      onNotice: (notice) => lifecycleNotice.value = notice);
  final realtimeStatus = ValueNotifier<(bool, String?)>((false, null));
  final notifications = <AxNotification>[];
  final unreadNotifications = ValueNotifier<int>(0);
  final security = ValueNotifier<AxAccountSecurity?>(null);
  final pendingRunPrompt = ValueNotifier<String?>(null);
  final securityError = ValueNotifier<String?>(null);
  final securityLoading = ValueNotifier<bool>(false);

  /// Legacy execution-only projection. Collaboration state belongs to queries.
  AxSnapshot get execution => _execution;
  void replaceExecution(AxSnapshot value) {
    runs.replace(value.run);
    final previous = _execution;
    _execution = AxSnapshot(
      workspaceId: value.workspaceId,
      activeRunId: value.activeRunId,
      run: value.run,
      projects: const [],
      tasks: List.unmodifiable(value.tasks),
      findings: List.unmodifiable(value.findings),
      events: List.unmodifiable(value.events),
      artifacts: List.unmodifiable(value.artifacts),
      candidateOutputs: List.unmodifiable(value.candidateOutputs),
      synthesisDecision: value.synthesisDecision,
    );
    if (previous.run != value.run ||
        previous.workspaceId != value.workspaceId ||
        previous.activeRunId != value.activeRunId ||
        !listEquals(previous.tasks, value.tasks) ||
        !listEquals(previous.findings, value.findings) ||
        !listEquals(previous.events, value.events) ||
        !listEquals(previous.artifacts, value.artifacts) ||
        !listEquals(previous.candidateOutputs, value.candidateOutputs) ||
        previous.synthesisDecision != value.synthesisDecision) {
      executionChanges.bump();
    }
  }

  void _updateUnreadNotifications() {
    unreadNotifications.value =
        notifications.where((n) => !n.read).length + invitations.items.length;
  }

  Future<void> acceptInvitation(AxProjectInvitation invite) =>
      collaboration.acceptInvitation(invite);

  Future<void> declineInvitation(AxProjectInvitation invite) =>
      collaboration.declineInvitation(invite);

  void dispose() {
    invitations.removeListener(_updateUnreadNotifications);
    invitations.dispose();
    lifecycle.dispose();
    lifecycleNotice.dispose();
    persistence.dispose();
    _disposed = true;
    _sessionGeneration++;
    projects.dispose();
    workspaces.dispose();
    executionChanges.dispose();
    realtimeStatus.dispose();
    unreadNotifications.dispose();
    security.dispose();
    securityLoading.dispose();
    securityError.dispose();
    pendingRunPrompt.dispose();
  }

  final AxDataSource dataSource;
  final AxSyncEngine syncEngine = AxSyncEngine();
  late final UserInvitationsStore invitations =
      UserInvitationsStore(dataSource, engine: syncEngine);
  late final AxSessionCatalogs catalogs =
      AxSessionCatalogs(dataSource, engine: syncEngine);
  late final AxProjectTabQueries projectTabs =
      AxProjectTabQueries(dataSource, engine: syncEngine);
  late final AxProjectWorkspaceGrants projectWorkspaceGrants =
      AxProjectWorkspaceGrants(dataSource, engine: syncEngine);
  late final AxProjectWorkstreams projectWorkstreams =
      AxProjectWorkstreams(dataSource, engine: syncEngine);
  late final AxProjectDetails projectDetails =
      AxProjectDetails(dataSource, engine: syncEngine);
  late final AxDiscussionCache discussion =
      AxDiscussionCache(dataSource, engine: syncEngine);

  late final AxWorkHistoryCache workHistory =
      AxWorkHistoryCache(dataSource, engine: syncEngine);

  late final AxWorkRealtimeSync workRealtime =
      AxWorkRealtimeSync.forCache(workHistory);

  late final realtimeCacheRouter = AxRealtimeCacheRouter(syncEngine,
      projectRemoved: projectWorkspaceGrants.remove,
      discussionChanged: discussion.reconcileSignal,
      discussionObserved: discussion.isObserved,
      discussionResynchronize: (id) async {
    await discussion.synchronize(id, reconcileNewest: false);
  });

  /// Existing HTTP APIs expose user-wide lists. Merge only the affected
  /// Workspace into retained state; no bootstrap or route selection is involved.
  Future<({AxWorkspace? workspace, List<AxWorker> workers})>
      resynchronizeWorkspace(String id) async {
    final stateQuery = AxQuery<AxWorkspace?>(
        key: AxQueryKey(['execution_workspace', id, 'state']),
        load: () async {
          final values = await dataSource.loadWorkspaces();
          for (final value in values) {
            if (value.id == id) return value;
          }
          return null;
        });
    final results = await Future.wait<Object?>([
      syncEngine.refresh<AxWorkspace?>(stateQuery),
      catalogs.refreshWorkers(),
    ]);
    final workspace = results[0] as AxWorkspace?;
    final workers = results[1] as List<AxWorker>;
    // Cleared/superseded recovery cannot update the legacy view projection.
    if (_disposed ||
        !syncEngine.peek(stateQuery).hasData ||
        !identical(syncEngine.peek(stateQuery).data, workspace) ||
        !identical(syncEngine.peek(catalogs.workers).data, workers)) {
      throw StateError('Workspace recovery superseded');
    }
    workspaces.replace([
      for (final item in workspaces.items)
        if (item.id != id) item,
      if (workspace != null) workspace,
    ]);
    return (
      workspace: workspace,
      workers: workers.where((worker) => worker.workspaceId == id).toList()
    );
  }

  void clearServerState() {
    final source = dataSource;
    if (source is AxConditionalReadCache) {
      (source as AxConditionalReadCache).clearConditionalReads();
    }
    lifecycle.reset();
    unawaited(persistence.clearUser());
    _sessionGeneration++;
    projects.clear();
    workspaces.clear();
    security.value = null;
    securityError.value = null;
    pendingRunPrompt.value = null;
    realtimeStatus.value = (false, null);
    securityLoading.value = false;
    notifications.clear();
    unreadNotifications.value = 0;
    projectWorkspaceGrants.clear();
    realtimeCacheRouter.reset();
    workRealtime.reset();
    collaboration.clear();
    workHistory.clear();
    discussion.clear();
    syncEngine.clear();
    replaceExecution(AxSnapshot.empty());
  }

  final AuthStore auth;
  late final WorkspaceStore workspaces =
      WorkspaceStore(dataSource, engine: syncEngine);
  late final ProjectStore projects =
      ProjectStore(dataSource, engine: syncEngine);
  late final collaboration =
      AxCollaborationMutations(dataSource, engine: syncEngine);
  final RunStore runs;

  /// Bootstrap/recovery only; navigation uses focused queries.
  Future<AxSnapshot> loadBootstrapState(
      {String? projectId, String? workspaceId}) async {
    final generation = _sessionGeneration;
    final loaded = await dataSource.loadBootstrapState(
        projectId: projectId, workspaceId: workspaceId);
    if (_disposed || generation != _sessionGeneration) {
      throw StateError('Bootstrap superseded');
    }
    final snapshot = loaded.copyWith(
        projects: loaded.projects
            .map((project) => project.copyWith(workstreams: const []))
            .toList());
    projects.replace(snapshot.projects);
    workspaces.replace(snapshot.workspaces);
    auth.replace(snapshot.viewer);
    replaceExecution(snapshot);
    return snapshot;
  }
}

class ProjectStore extends ValueNotifier<List<AxProject>> {
  ProjectStore(this.source, {AxSyncEngine? engine})
      : engine = engine ?? AxSyncEngine(),
        super(const []) {
    _cancel = this.engine.watch(
        query, (state) => value = state.data ?? const [],
        fireImmediately: true);
  }
  final AxDataSource source;
  final AxSyncEngine engine;
  late final void Function() _cancel;
  late final query = AxQuery<List<AxProject>>(
      key: AxQueryKey(['projects']),
      load: () async => List.unmodifiable((await source.loadProjects())
          .map((p) => p.copyWith(workstreams: const []))));
  List<AxProject> get items => value;
  void clear() => engine.remove(query.key);
  @override
  void dispose() {
    _cancel();
    engine.remove(query.key);
    super.dispose();
  }

  void replace(List<AxProject> items) {
    if (listEquals(value, items)) return;
    engine.update(
        query,
        (_) => List.unmodifiable(
            items.map((p) => p.copyWith(workstreams: const []))));
  }

  Future<List<AxProject>> refresh() => engine.refresh(query, supersede: true);
}

class WorkspaceStore extends ValueNotifier<List<AxWorkspace>> {
  WorkspaceStore(this.source, {AxSyncEngine? engine})
      : engine = engine ?? AxSyncEngine(),
        super(const []) {
    _cancel = this.engine.watch(
        query, (state) => value = state.data ?? const [],
        fireImmediately: true);
  }
  final AxSyncEngine engine;
  late final void Function() _cancel;
  late final query = ownedWorkspacesQuery(source);
  final AxDataSource source;
  int _generation = 0;
  bool _disposed = false;
  void clear() {
    _generation++;
    engine.remove(query.key);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _cancel();
    engine.remove(query.key);
    super.dispose();
  }

  List<AxWorkspace> get items => value;

  void replace(List<AxWorkspace> items) {
    if (!listEquals(value, items)) {
      engine.update(query, (_) => List.unmodifiable(items));
    }
  }

  Future<List<AxWorkspace>> list() async {
    final generation = ++_generation;
    final value = await source.loadWorkspaces();
    if (!_disposed && generation == _generation) replace(value);
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
  int _generation = 0;
  bool _loggingOut = false;

  void replace(AxViewer? value) {
    if (value != null) viewer = value;
  }

  Future<AxSession> load() async {
    if (_loggingOut) throw StateError('Logout in progress');
    final generation = ++_generation;
    final value = await source.loadSession();
    if (generation != _generation) {
      throw StateError('Authentication load superseded');
    }
    session = value;
    viewer = value.viewer;
    return value;
  }

  Future<void> logout() async {
    _generation++;
    _loggingOut = true;
    try {
      await source.logout();
      session = const AxSession(authenticated: false);
      viewer = null;
    } finally {
      _generation++;
      _loggingOut = false;
    }
  }
}

/// Explicit notification boundary for retained execution projections.
class AxViewSignal extends ChangeNotifier {
  void bump() => notifyListeners();
}

class UserInvitationsStore extends ValueNotifier<List<AxProjectInvitation>> {
  UserInvitationsStore(this.source, {AxSyncEngine? engine})
      : engine = engine ?? AxSyncEngine(),
        super(const []) {
    _cancel = this.engine.watch(
        query, (state) => value = state.data ?? const [],
        fireImmediately: true);
  }
  final AxDataSource source;
  final AxSyncEngine engine;
  late final void Function() _cancel;
  late final query = AxQuery<List<AxProjectInvitation>>(
      key: AxQueryKey(['me', 'invitations']),
      load: source.loadCurrentUserInvitations);

  List<AxProjectInvitation> get items => value;
  void clear() => engine.remove(query.key);

  @override
  void dispose() {
    _cancel();
    engine.remove(query.key);
    super.dispose();
  }

  void replace(List<AxProjectInvitation> items) {
    if (listEquals(value, items)) return;
    engine.update(query, (_) => List.unmodifiable(items));
  }

  Future<List<AxProjectInvitation>> refresh() =>
      engine.refresh(query, supersede: true);
}
