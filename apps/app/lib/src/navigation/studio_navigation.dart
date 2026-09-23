enum StudioRouteKind {
  home,
  projects,
  project,
  chat,
  run,
  hosts,
  workers,
  accounts,
  usage,
  workspaceSettings,
  profileSecurity,
  login,
}

class StudioNavigation {
  const StudioNavigation._({
    required this.kind,
    this.projectId,
    this.chatId,
    this.runId,
    this.loginReturnTo,
  });

  const StudioNavigation.home() : this._(kind: StudioRouteKind.home);

  const StudioNavigation.projects() : this._(kind: StudioRouteKind.projects);

  const StudioNavigation.project(String projectId)
      : this._(kind: StudioRouteKind.project, projectId: projectId);

  const StudioNavigation.chat(String projectId, String chatId)
      : this._(
            kind: StudioRouteKind.chat, projectId: projectId, chatId: chatId);

  const StudioNavigation.run(String projectId, String runId)
      : this._(kind: StudioRouteKind.run, projectId: projectId, runId: runId);

  const StudioNavigation.hosts() : this._(kind: StudioRouteKind.hosts);

  const StudioNavigation.workers() : this._(kind: StudioRouteKind.workers);

  const StudioNavigation.accounts() : this._(kind: StudioRouteKind.accounts);

  const StudioNavigation.usage() : this._(kind: StudioRouteKind.usage);

  const StudioNavigation.workspaceSettings()
      : this._(kind: StudioRouteKind.workspaceSettings);

  const StudioNavigation.login({String? returnTo})
      : this._(kind: StudioRouteKind.login, loginReturnTo: returnTo);

  const StudioNavigation.profileSecurity()
      : this._(kind: StudioRouteKind.profileSecurity);

  /// Compatibility parser for old links. New links serialize canonically.
  const StudioNavigation.account()
      : this._(kind: StudioRouteKind.profileSecurity);

  final StudioRouteKind kind;
  final String? projectId;
  final String? chatId;
  final String? runId;
  final String? loginReturnTo;

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
    if (parts case ['hosts']) return const StudioNavigation.hosts();
    if (parts case ['workers']) return const StudioNavigation.workers();
    if (parts case ['accounts']) return const StudioNavigation.accounts();
    if (parts case ['usage']) return const StudioNavigation.usage();
    if (parts case ['settings', 'workspace']) {
      return const StudioNavigation.workspaceSettings();
    }
    if (parts.length >= 4 && parts[0] == 'projects') {
      if (parts[2] == 'chats') {
        return StudioNavigation.chat(parts[1], parts[3]);
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
      StudioRouteKind.run => Uri(path: '/projects/$projectId/runs/$runId'),
      StudioRouteKind.hosts => Uri(path: '/hosts'),
      StudioRouteKind.workers => Uri(path: '/workers'),
      StudioRouteKind.accounts => Uri(path: '/accounts'),
      StudioRouteKind.usage => Uri(path: '/usage'),
      StudioRouteKind.workspaceSettings => Uri(path: '/settings/workspace'),
      StudioRouteKind.login => Uri(
          path: '/login',
          queryParameters:
              loginReturnTo == null ? null : {'returnTo': loginReturnTo}),
      StudioRouteKind.profileSecurity => Uri(path: '/settings/profile'),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is StudioNavigation &&
      other.kind == kind &&
      other.projectId == projectId &&
      other.chatId == chatId &&
      other.runId == runId &&
      other.loginReturnTo == loginReturnTo;

  @override
  int get hashCode =>
      Object.hash(kind, projectId, chatId, runId, loginReturnTo);
}
