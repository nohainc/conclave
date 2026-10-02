enum AxRouteKind {
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

class AxNavigation {
  const AxNavigation._({
    required this.kind,
    this.projectId,
    this.workstreamId,
    this.runId,
    this.workspaceId,
    this.loginReturnTo,
    this.searchQuery,
    this.desktopAuthIntentId,
  });

  const AxNavigation.home() : this._(kind: AxRouteKind.home);

  const AxNavigation.projects() : this._(kind: AxRouteKind.projects);

  const AxNavigation.project(String projectId)
      : this._(kind: AxRouteKind.project, projectId: projectId);

  const AxNavigation.workstream(String projectId, String workstreamId)
      : this._(
            kind: AxRouteKind.workstream,
            projectId: projectId,
            workstreamId: workstreamId);

  const AxNavigation.run(String projectId, String runId, {String? workstreamId})
      : this._(
          kind: AxRouteKind.run,
          projectId: projectId,
          runId: runId,
          workstreamId: workstreamId,
        );

  const AxNavigation.workspaces({String? workspaceId})
      : this._(kind: AxRouteKind.workspaces, workspaceId: workspaceId);

  const AxNavigation.workspace(String workspaceId)
      : this._(kind: AxRouteKind.workspaces, workspaceId: workspaceId);

  const AxNavigation.login({String? returnTo})
      : this._(kind: AxRouteKind.login, loginReturnTo: returnTo);

  const AxNavigation.profileSecurity()
      : this._(kind: AxRouteKind.profileSecurity);

  const AxNavigation.search([String? query])
      : this._(kind: AxRouteKind.search, searchQuery: query);

  const AxNavigation.desktopAuthApproval(String intentId)
      : this._(
            kind: AxRouteKind.desktopAuthApproval,
            desktopAuthIntentId: intentId);

  final AxRouteKind kind;
  final String? projectId;
  final String? workstreamId;
  final String? runId;
  final String? workspaceId;
  final String? loginReturnTo;
  final String? searchQuery;
  final String? desktopAuthIntentId;

  factory AxNavigation.fromUri(Uri uri) {
    final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
    final parts = segments.toList(growable: false);
    if (parts case ['login']) {
      return AxNavigation.login(returnTo: uri.queryParameters['returnTo']);
    }
    if (parts case ['desktop-auth', 'approve']) {
      final intentId = uri.queryParameters['intentId'];
      if (intentId != null && intentId.isNotEmpty) {
        return AxNavigation.desktopAuthApproval(intentId);
      }
    }
    if (parts case ['settings', 'profile']) {
      return const AxNavigation.profileSecurity();
    }
    if (parts case ['projects']) return const AxNavigation.projects();
    if (parts.length == 1 && parts[0] == 'workspaces') {
      return const AxNavigation.workspaces();
    }
    if (parts.length == 2 &&
        parts[0] == 'workspaces' &&
        parts[1] != 'workers' &&
        parts[1] != 'accounts') {
      return AxNavigation.workspaces(workspaceId: parts[1]);
    }
    if (parts case ['search']) {
      return AxNavigation.search(uri.queryParameters['q']);
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
      return AxNavigation.run(pId, rId, workstreamId: wsId);
    }
    if (parts.length >= 4 && parts[0] == 'projects') {
      if (parts[2] == 'workstreams') {
        return AxNavigation.workstream(parts[1], parts[3]);
      }
      if (parts[2] == 'runs') {
        return AxNavigation.run(parts[1], parts[3]);
      }
    }
    if (parts.length == 2 && parts[0] == 'projects') {
      return AxNavigation.project(parts[1]);
    }
    return const AxNavigation.home();
  }

  Uri toUri() {
    return switch (kind) {
      AxRouteKind.home => Uri(path: '/'),
      AxRouteKind.projects => Uri(path: '/projects'),
      AxRouteKind.project => Uri(path: '/projects/$projectId'),
      AxRouteKind.workstream =>
        Uri(path: '/projects/$projectId/workstreams/$workstreamId'),
      AxRouteKind.run => workstreamId != null
          ? Uri(
              path:
                  '/projects/$projectId/workstreams/$workstreamId/runs/$runId')
          : Uri(path: '/projects/$projectId/runs/$runId'),
      AxRouteKind.workspaces => workspaceId != null
          ? Uri(path: '/workspaces/$workspaceId')
          : Uri(path: '/workspaces'),
      AxRouteKind.login => Uri(
          path: '/login',
          queryParameters:
              loginReturnTo == null ? null : {'returnTo': loginReturnTo}),
      AxRouteKind.profileSecurity => Uri(path: '/settings/profile'),
      AxRouteKind.search => Uri(
          path: '/search',
          queryParameters: (searchQuery != null && searchQuery!.isNotEmpty)
              ? {'q': searchQuery!}
              : null,
        ),
      AxRouteKind.desktopAuthApproval => Uri(
          path: '/desktop-auth/approve',
          queryParameters: desktopAuthIntentId == null
              ? null
              : {'intentId': desktopAuthIntentId},
        ),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is AxNavigation &&
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
