enum StudioRouteKind {
  home,
  projects,
  project,
  chat,
  workstream,
  run,
  hosts,
  workers,
  usage,
  profileSecurity,
  login,
  search,
}

class StudioNavigation {
  const StudioNavigation._({
    required this.kind,
    this.projectId,
    this.chatId,
    this.workstreamId,
    this.runId,
    this.loginReturnTo,
    this.searchQuery,
  });

  const StudioNavigation.home() : this._(kind: StudioRouteKind.home);

  const StudioNavigation.projects() : this._(kind: StudioRouteKind.projects);

  const StudioNavigation.project(String projectId)
      : this._(kind: StudioRouteKind.project, projectId: projectId);

  const StudioNavigation.chat(String projectId, String chatId)
      : this._(
            kind: StudioRouteKind.chat, projectId: projectId, chatId: chatId);

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

  const StudioNavigation.hosts() : this._(kind: StudioRouteKind.hosts);

  const StudioNavigation.workers() : this._(kind: StudioRouteKind.workers);

  const StudioNavigation.usage() : this._(kind: StudioRouteKind.usage);

  const StudioNavigation.login({String? returnTo})
      : this._(kind: StudioRouteKind.login, loginReturnTo: returnTo);

  const StudioNavigation.profileSecurity()
      : this._(kind: StudioRouteKind.profileSecurity);

  const StudioNavigation.search([String? query])
      : this._(kind: StudioRouteKind.search, searchQuery: query);

  /// Compatibility parser for old links. New links serialize canonically.
  const StudioNavigation.account()
      : this._(kind: StudioRouteKind.profileSecurity);

  final StudioRouteKind kind;
  final String? projectId;
  final String? chatId;
  final String? workstreamId;
  final String? runId;
  final String? loginReturnTo;
  final String? searchQuery;

  factory StudioNavigation.fromUri(Uri uri) {
    final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
    final parts = segments.toList(growable: false);
    if (parts case ['login']) {
      return StudioNavigation.login(returnTo: uri.queryParameters['returnTo']);
    }
    if (parts case ['account']) {
      return const StudioNavigation.profileSecurity();
    }
    if (parts case ['settings', 'profile']) {
      return const StudioNavigation.profileSecurity();
    }
    if (parts case ['projects']) return const StudioNavigation.projects();
    if ((parts.length == 1 && parts[0] == 'execution') ||
        (parts.length == 2 &&
            parts[0] == 'execution' &&
            parts[1] == 'workspaces')) {
      return const StudioNavigation.hosts();
    }
    if (parts case ['execution', 'workers']) {
      return const StudioNavigation.workers();
    }
    if (parts.length == 1 &&
        (parts[0] == 'workspaces' || parts[0] == 'hosts')) {
      final tab = uri.queryParameters['tab']?.toLowerCase();
      if (tab == 'workers') return const StudioNavigation.workers();
      if (tab == 'accounts' || tab == 'ai_accounts') {
        return const StudioNavigation.workers();
      }
      return const StudioNavigation.hosts();
    }
    if (parts.length == 2 &&
        (parts[0] == 'workspaces' || parts[0] == 'hosts')) {
      if (parts[1] == 'workers') return const StudioNavigation.workers();
      if (parts[1] == 'accounts') return const StudioNavigation.workers();
    }
    // Backward compatibility for standalone /workers and /accounts
    if (parts case ['workers']) return const StudioNavigation.workers();
    if (parts case ['accounts']) return const StudioNavigation.workers();
    if (parts case ['usage']) return const StudioNavigation.usage();
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
      if (parts[2] == 'chats') {
        return StudioNavigation.chat(parts[1], parts[3]);
      }
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
      StudioRouteKind.chat => Uri(path: '/projects/$projectId/chats/$chatId'),
      StudioRouteKind.workstream =>
        Uri(path: '/projects/$projectId/workstreams/$workstreamId'),
      StudioRouteKind.run => workstreamId != null
          ? Uri(
              path:
                  '/projects/$projectId/workstreams/$workstreamId/runs/$runId')
          : Uri(path: '/projects/$projectId/runs/$runId'),
      StudioRouteKind.hosts => Uri(path: '/execution/workspaces'),
      StudioRouteKind.workers => Uri(path: '/execution/workers'),
      StudioRouteKind.usage => Uri(path: '/usage'),
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
    };
  }

  @override
  bool operator ==(Object other) =>
      other is StudioNavigation &&
      other.kind == kind &&
      other.projectId == projectId &&
      other.chatId == chatId &&
      other.workstreamId == workstreamId &&
      other.runId == runId &&
      other.loginReturnTo == loginReturnTo &&
      other.searchQuery == searchQuery;

  @override
  int get hashCode => Object.hash(
      kind, projectId, chatId, workstreamId, runId, loginReturnTo, searchQuery);
}
