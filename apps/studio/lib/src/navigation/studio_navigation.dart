enum StudioRouteKind { home, project, chat, run, login }

class StudioNavigation {
  const StudioNavigation._({
    required this.kind,
    this.projectId,
    this.chatId,
    this.runId,
  });

  const StudioNavigation.home() : this._(kind: StudioRouteKind.home);

  const StudioNavigation.project(String projectId)
      : this._(kind: StudioRouteKind.project, projectId: projectId);

  const StudioNavigation.chat(String projectId, String chatId)
      : this._(
            kind: StudioRouteKind.chat, projectId: projectId, chatId: chatId);

  const StudioNavigation.run(String projectId, String runId)
      : this._(kind: StudioRouteKind.run, projectId: projectId, runId: runId);

  final StudioRouteKind kind;
  final String? projectId;
  final String? chatId;
  final String? runId;

  factory StudioNavigation.fromUri(Uri uri) {
    final segments = uri.pathSegments.where((segment) => segment.isNotEmpty);
    final parts = segments.toList(growable: false);
    if (parts case ['login']) {
      return const StudioNavigation._(kind: StudioRouteKind.login);
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
      StudioRouteKind.project => Uri(path: '/projects/$projectId'),
      StudioRouteKind.chat => Uri(path: '/projects/$projectId/chats/$chatId'),
      StudioRouteKind.run => Uri(path: '/projects/$projectId/runs/$runId'),
      StudioRouteKind.login => Uri(path: '/login'),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is StudioNavigation &&
      other.kind == kind &&
      other.projectId == projectId &&
      other.chatId == chatId &&
      other.runId == runId;

  @override
  int get hashCode => Object.hash(kind, projectId, chatId, runId);
}
