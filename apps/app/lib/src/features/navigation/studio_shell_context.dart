import '../../navigation/studio_navigation.dart';
import '../../studio/studio_models.dart';

/// Context model encapsulating state needed by the Conclave AX App Shell (Sidebar & HUD).
class StudioShellContext {
  const StudioShellContext({
    required this.navigation,
    required this.projects,
    this.selectedProject,
    this.selectedWorkstream,
    this.selectedRun,
    this.workspaces = const [],
    this.workers = const [],
    this.accounts = const [],
    this.unreadNotificationCount = 0,
    this.isDarkTheme = true,
    this.realtimeStale = false,
    this.realtimeNotice,
    this.viewerDisplayName,
    this.viewerEmail,
    this.expandedProjectIds = const {},
  });

  final StudioNavigation navigation;
  final List<StudioProject> projects;
  final StudioProject? selectedProject;
  final StudioWorkstream? selectedWorkstream;
  final StudioRun? selectedRun;
  final List<StudioAgent> workspaces;
  final List<StudioWorker> workers;
  final List<StudioCredentialProfile> accounts;
  final int unreadNotificationCount;
  final bool isDarkTheme;
  final bool realtimeStale;
  final String? realtimeNotice;
  final String? viewerDisplayName;
  final String? viewerEmail;
  final Set<String> expandedProjectIds;

  int get onlineWorkspaceCount =>
      workspaces.where((w) => w.status.toLowerCase() == 'online').length;

  String? get primaryWorkspaceLabel {
    final online = workspaces
        .where((w) => w.status.toLowerCase() == 'online')
        .firstOrNull;
    if (online != null) {
      return '${online.name} · Online';
    }
    if (workspaces.isNotEmpty) {
      return '${workspaces.first.name} · Offline';
    }
    return 'No Workspaces';
  }

  bool get hasOnlineWorkspace => onlineWorkspaceCount > 0;

  String get viewerInitials {
    final name = (viewerDisplayName ?? viewerEmail ?? '').trim();
    if (name.isEmpty) return '?';
    final parts = name.split(RegExp(r'\s+')).where((part) => part.isNotEmpty);
    final initials = parts.take(2).map((part) => part[0]).join();
    return initials.isNotEmpty ? initials.toUpperCase() : '?';
  }

  bool isProjectExpanded(String projectId) =>
      expandedProjectIds.contains(projectId);

  bool isNavActive(StudioNavigation? target) {
    if (target == null) return false;
    if (target.kind == StudioRouteKind.home) {
      return navigation.kind == StudioRouteKind.home;
    }
    if (target.kind == StudioRouteKind.projects) {
      return navigation.kind == StudioRouteKind.projects;
    }
    if (target.kind == StudioRouteKind.project) {
      return (navigation.kind == StudioRouteKind.project ||
              navigation.kind == StudioRouteKind.workstream ||
              navigation.kind == StudioRouteKind.run ||
              navigation.kind == StudioRouteKind.chat) &&
          navigation.projectId == target.projectId;
    }
    return navigation.kind == target.kind;
  }
}
