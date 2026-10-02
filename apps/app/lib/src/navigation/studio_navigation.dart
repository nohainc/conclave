enum StudioRouteKind {
  home,
  projects,
  project,
  workstream,
  run,
  workspaces,
  profileSecurity,
  login,
  search,
  desktopAuthApproval,
}

class StudioNavigation {
  const StudioNavigation._({
    required this.kind,
    this.projectId,
    this.workstreamId,
    this.runId,
    this.workspaceId,
    this.loginReturnTo,
    this.searchQuery,
    this.desktopAuthIntentId,
  });

  const StudioNavigation.home() : this._(kind: StudioRouteKind.home);

  const StudioNavigation.projects() : this._(kind: StudioRouteKind.projects);

  const StudioNavigation.project(String projectId)
      : this._(kind: StudioRouteKind.project, projectId: projectId);

  const StudioNavigation.workstream(String projectId, String workstreamId)
      : this._(
            kind: StudioRouteKind.workstream,
            projectId: projectId,
            workstreamId: workstreamId);

  const StudioNavigation.run(String projectId, String runId,
      {String? workstreamId})
      : this._(
          kind: StudioRouteKind.run,
          projectId: projectId,
          runId: runId,
          workstreamId: workstreamId,
        );

  const StudioNavigation.workspaces({String? workspaceId})
      : this._(kind: StudioRouteKind.workspaces, workspaceId: workspaceId);

  const StudioNavigation.workspace(String workspaceId)
      : this._(kind: StudioRouteKind.workspaces, workspaceId: workspaceId);

  const StudioNavigation.login({String? returnTo})
      : this._(kind: StudioRouteKind.login, loginReturnTo: returnTo);

  const StudioNavigation.profileSecurity()
      : this._(kind: StudioRouteKind.profileSecurity);

  const StudioNavigation.search([String? query])
      : this._(kind: StudioRouteKind.search, searchQuery: query);

  const StudioNavigation.desktopAuthApproval(String intentId)
      : this._(
            kind: StudioRouteKind.desktopAuthApproval,
            desktopAuthIntentId: intentId);

  final StudioRouteKind kind;
  final String? projectId;
  final String? workstreamId;
  final String? runId;
  final String? workspaceId;
  final String? loginReturnTo;
  final String? searchQuery;
  final String? desktopAuthIntentId;

  factory StudioNavigation.fromUri(Uri uri) {
    final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
    final parts = segments.toList(growable: false);
    if (parts case ['login']) {
      return StudioNavigation.login(returnTo: uri.queryParameters['returnTo']);
    }
    if (parts case ['desktop-auth', 'approve']) {
      final intentId = uri.queryParameters['intentId'];
      if (intentId != null && intentId.isNotEmpty) {
        return StudioNavigation.desktopAuthApproval(intentId);
      }
    }
    if (parts case ['settings', 'profile']) {
      return const StudioNavigation.profileSecurity();
    }
    if (parts case ['projects']) return const StudioNavigation.projects();
    if (parts.length == 1 && parts[0] == 'workspaces') {
      return const StudioNavigation.workspaces();
    }
    if (parts.length == 2 &&
        parts[0] == 'workspaces' &&
        parts[1] != 'workers' &&
        parts[1] != 'accounts') {
      return StudioNavigation.workspaces(workspaceId: parts[1]);
    }
    if (parts case ['search']) {
      return StudioNavigation.search(uri.queryParameters['q']);
    }
    if (parts
        case [
          'projects',
          final pId,
          'workstreams',
          final wsId,
          'runs',
          final rId
        ]) {
      return StudioNavigation.run(pId, rId, workstreamId: wsId);
    }
    if (parts.length >= 4 && parts[0] == 'projects') {
      if (parts[2] == 'workstreams') {
        return StudioNavigation.workstream(parts[1], parts[3]);
      }
      if (parts[2] == 'runs') {
        return StudioNavigation.run(parts[1], parts[3]);
      }
    }
    if (parts.length == 2 && parts[0] == 'projects') {
      return StudioNavigation.project(parts[1]);
    }
    return const StudioNavigation.home();
  }

  Uri toUri() {
    return switch (kind) {
      StudioRouteKind.home => Uri(path: '/'),
      StudioRouteKind.projects => Uri(path: '/projects'),
      StudioRouteKind.project => Uri(path: '/projects/$projectId'),
      StudioRouteKind.workstream =>
        Uri(path: '/projects/$projectId/workstreams/$workstreamId'),
      StudioRouteKind.run => workstreamId != null
          ? Uri(
              path:
                  '/projects/$projectId/workstreams/$workstreamId/runs/$runId')
          : Uri(path: '/projects/$projectId/runs/$runId'),
      StudioRouteKind.workspaces => workspaceId != null
          ? Uri(path: '/workspaces/$workspaceId')
          : Uri(path: '/workspaces'),
      StudioRouteKind.login => Uri(
          path: '/login',
          queryParameters:
              loginReturnTo == null ? null : {'returnTo': loginReturnTo}),
      StudioRouteKind.profileSecurity => Uri(path: '/settings/profile'),
      StudioRouteKind.search => Uri(
          path: '/search',
          queryParameters: (searchQuery != null && searchQuery!.isNotEmpty)
              ? {'q': searchQuery!}
              : null,
        ),
      StudioRouteKind.desktopAuthApproval => Uri(
          path: '/desktop-auth/approve',
          queryParameters: desktopAuthIntentId == null
              ? null
              : {'intentId': desktopAuthIntentId},
        ),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is StudioNavigation &&
      other.kind == kind &&
      other.projectId == projectId &&
      other.workstreamId == workstreamId &&
      other.runId == runId &&
      other.workspaceId == workspaceId &&
      other.loginReturnTo == loginReturnTo &&
      other.searchQuery == searchQuery &&
      other.desktopAuthIntentId == desktopAuthIntentId;

  @override
  int get hashCode => Object.hash(kind, projectId, workstreamId, runId,
      workspaceId, loginReturnTo, searchQuery, desktopAuthIntentId);
}
