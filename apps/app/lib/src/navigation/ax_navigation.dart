enum AxRouteKind {
  home,
  spaces,
  space,
  thread,
  run,
  workflows,
  workspaces,
  profileSecurity,
  login,
  search,
  desktopAuthApproval,
}

class AxNavigation {
  const AxNavigation._({
    required this.kind,
    this.spaceId,
    this.threadId,
    this.runId,
    this.workspaceId,
    this.loginReturnTo,
    this.searchQuery,
    this.desktopAuthIntentId,
  });

  const AxNavigation.home() : this._(kind: AxRouteKind.home);

  const AxNavigation.spaces() : this._(kind: AxRouteKind.spaces);

  const AxNavigation.space(String spaceId)
      : this._(kind: AxRouteKind.space, spaceId: spaceId);

  const AxNavigation.thread(String spaceId, String threadId)
      : this._(kind: AxRouteKind.thread, spaceId: spaceId, threadId: threadId);

  const AxNavigation.run(String spaceId, String runId, {String? threadId})
      : this._(
          kind: AxRouteKind.run,
          spaceId: spaceId,
          runId: runId,
          threadId: threadId,
        );

  const AxNavigation.workflows() : this._(kind: AxRouteKind.workflows);

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
  final String? spaceId;
  final String? threadId;
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
    if (parts case ['spaces'] || ['spaces']) return const AxNavigation.spaces();
    if (parts case ['workflows']) return const AxNavigation.workflows();
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
        case ['spaces', final sId, 'threads', final tId, 'runs', final rId]) {
      return AxNavigation.run(sId, rId, threadId: tId);
    }
    if (parts.length >= 4 && (parts[0] == 'spaces')) {
      if (parts[2] == 'threads') {
        return AxNavigation.thread(parts[1], parts[3]);
      }
      if (parts[2] == 'runs') {
        return AxNavigation.run(parts[1], parts[3]);
      }
    }
    if (parts.length == 2 && (parts[0] == 'spaces')) {
      return AxNavigation.space(parts[1]);
    }
    return const AxNavigation.home();
  }

  Uri toUri() {
    return switch (kind) {
      AxRouteKind.home => Uri(path: '/'),
      AxRouteKind.spaces => Uri(path: '/spaces'),
      AxRouteKind.space => Uri(path: '/spaces/$spaceId'),
      AxRouteKind.thread => Uri(path: '/spaces/$spaceId/threads/$threadId'),
      AxRouteKind.run => threadId != null
          ? Uri(path: '/spaces/$spaceId/threads/$threadId/runs/$runId')
          : Uri(path: '/spaces/$spaceId/runs/$runId'),
      AxRouteKind.workflows => Uri(path: '/workflows'),
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
      other.spaceId == spaceId &&
      other.threadId == threadId &&
      other.runId == runId &&
      other.workspaceId == workspaceId &&
      other.loginReturnTo == loginReturnTo &&
      other.searchQuery == searchQuery &&
      other.desktopAuthIntentId == desktopAuthIntentId;

  @override
  int get hashCode => Object.hash(kind, spaceId, threadId, runId, workspaceId,
      loginReturnTo, searchQuery, desktopAuthIntentId);
}
