import '../../ax/sync/ax_query_builder.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../navigation/ax_navigation.dart';
import '../../ax/ax_models.dart';
import '../../ax/sync/ax_project_workstreams.dart';

enum ExecutionStatusTone {
  usable,
  degraded,
  neutral,
  failed,
}

extension ExecutionStatusToneHelpers on ExecutionStatusTone {
  Color color(bool isDark) {
    switch (this) {
      case ExecutionStatusTone.usable:
        return ConclaveBrand.success;
      case ExecutionStatusTone.degraded:
        return ConclaveBrand.warning;
      case ExecutionStatusTone.neutral:
        return isDark ? Colors.white38 : ConclaveBrand.lightInkMuted;
      case ExecutionStatusTone.failed:
        return ConclaveBrand.error;
    }
  }
}

/// Context model encapsulating state needed by the Conclave AX App Shell (Sidebar & HUD).
class AxShellContext {
  const AxShellContext({
    required this.navigation,
    required List<AxProject> projects,
    this.projectListenable,
    this.workspaceListenable,
    this.projectWorkstreams,
    this.workstreamsByProject = const {},
    this.selectedProject,
    this.selectedWorkstream,
    this.selectedRun,
    List<AxWorkspace> workspaces = const [],
    int unreadNotificationCount = 0,
    this.unreadNotifications,
    this.invitationsListenable,
    this.isDarkTheme = true,
    this.themeMode = ThemeMode.system,
    bool realtimeStale = false,
    String? realtimeNotice,
    this.realtimeListenable,
    this.viewerDisplayName,
    this.viewerEmail,
    this.expandedProjectIds = const {},
  })  : _projects = projects,
        _workspaces = workspaces,
        _unreadNotificationCount = unreadNotificationCount,
        _realtimeStale = realtimeStale,
        _realtimeNotice = realtimeNotice;

  final AxNavigation navigation;
  final List<AxProject> _projects;
  final ValueListenable<List<AxProject>>? projectListenable;
  List<AxProject> get projects => projectListenable?.value ?? _projects;
  final AxProjectWorkstreams? projectWorkstreams;
  final Map<String, List<AxWorkstream>> workstreamsByProject;
  final AxProject? selectedProject;
  final AxWorkstream? selectedWorkstream;
  final AxRun? selectedRun;
  final List<AxWorkspace> _workspaces;
  final ValueListenable<List<AxWorkspace>>? workspaceListenable;
  List<AxWorkspace> get workspaces => workspaceListenable?.value ?? _workspaces;
  final int _unreadNotificationCount;
  final ValueListenable<int>? unreadNotifications;
  final ValueListenable<List<AxProjectInvitation>>? invitationsListenable;
  List<AxProjectInvitation> get invitations =>
      invitationsListenable?.value ?? const [];
  int get unreadNotificationCount =>
      unreadNotifications?.value ?? _unreadNotificationCount;
  Widget watchNotifications(Widget Function() build) {
    final listenable = unreadNotifications;
    return listenable == null
        ? build()
        : ValueListenableBuilder<int>(
            valueListenable: listenable, builder: (context, _, __) => build());
  }

  Widget watchInvitations(Widget Function() build) {
    final listenable = invitationsListenable;
    return listenable == null
        ? build()
        : ValueListenableBuilder<List<AxProjectInvitation>>(
            valueListenable: listenable, builder: (context, _, __) => build());
  }

  Widget watchProjectsAndWorkstreams(Widget Function() build) {
    Widget collections(int index) {
      final cache = projectWorkstreams;
      if (cache == null || index >= projects.length) return build();
      return AxQueryBuilder<List<AxWorkstream>>(
          engine: cache.engine,
          query: cache.query(projects[index].id),
          ensure: false,
          builder: (context, _) => collections(index + 1));
    }

    final listenable = projectListenable;
    return listenable == null
        ? collections(0)
        : ValueListenableBuilder<List<AxProject>>(
            valueListenable: listenable,
            builder: (context, _, __) => collections(0));
  }

  final bool isDarkTheme;
  final ThemeMode themeMode;
  final bool _realtimeStale;
  final String? _realtimeNotice;
  final ValueListenable<(bool, String?)>? realtimeListenable;
  bool get realtimeStale => realtimeListenable?.value.$1 ?? _realtimeStale;
  String? get realtimeNotice => realtimeListenable == null
      ? _realtimeNotice
      : realtimeListenable!.value.$2;
  Widget watchExecution(Widget Function() build) => ListenableBuilder(
      listenable: Listenable.merge([workspaceListenable, realtimeListenable]),
      builder: (context, _) => build());
  final String? viewerDisplayName;
  final String? viewerEmail;
  final Set<String> expandedProjectIds;

  int get onlineWorkspaceCount =>
      workspaces.where((w) => w.status.toLowerCase() == 'online').length;

  AxWorkspace? get targetedWorkspace {
    final workstream = selectedWorkstream;
    if (workstream != null &&
        workstream.primaryWorkspace.isNotEmpty &&
        workstream.primaryWorkspace != 'Not selected') {
      final query = workstream.primaryWorkspace.trim().toLowerCase();
      return workspaces.where((w) {
        return w.name.trim().toLowerCase() == query ||
            w.id.trim().toLowerCase() == query ||
            w.hostname.trim().toLowerCase() == query;
      }).firstOrNull;
    }
    return null;
  }

  bool get isWorkstreamContext =>
      selectedWorkstream != null ||
      navigation.kind == AxRouteKind.workstream ||
      navigation.kind == AxRouteKind.run;

  String get executionStatusLabel {
    if (isWorkstreamContext) {
      final target = targetedWorkspace;
      if (target != null) {
        final isOnline = target.status.toLowerCase() == 'online';
        final isDegraded = target.status.toLowerCase() == 'degraded' ||
            target.status.toLowerCase() == 'reconnecting';
        final statusText = isOnline
            ? 'Online'
            : isDegraded
                ? 'Degraded'
                : 'Offline';
        return '${target.name} · $statusText';
      }
      final customName = selectedWorkstream?.primaryWorkspace;
      if (customName != null &&
          customName.isNotEmpty &&
          customName != 'Not selected') {
        return '$customName · Offline';
      }
    }
    if (workspaces.isEmpty) {
      return 'No Workspaces';
    }
    final online = onlineWorkspaceCount;
    final total = workspaces.length;
    return '$online / $total ${total == 1 ? 'Workspace' : 'Workspaces'} online';
  }

  ExecutionStatusTone get executionStatusTone {
    if (realtimeStale) {
      return ExecutionStatusTone.degraded;
    }
    if (workspaces.isEmpty) {
      return ExecutionStatusTone.neutral;
    }
    if (isWorkstreamContext) {
      final target = targetedWorkspace;
      if (target != null) {
        final st = target.status.toLowerCase();
        if (st == 'online') return ExecutionStatusTone.usable;
        if (st == 'degraded' || st == 'reconnecting') {
          return ExecutionStatusTone.degraded;
        }
        return ExecutionStatusTone.failed;
      }
      final customName = selectedWorkstream?.primaryWorkspace;
      if (customName != null &&
          customName.isNotEmpty &&
          customName != 'Not selected') {
        return ExecutionStatusTone.failed;
      }
      return onlineWorkspaceCount > 0
          ? ExecutionStatusTone.usable
          : ExecutionStatusTone.failed;
    }
    if (onlineWorkspaceCount > 0) {
      return ExecutionStatusTone.usable;
    }
    return ExecutionStatusTone.failed;
  }

  String? get primaryWorkspaceLabel => executionStatusLabel;

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

  bool isNavActive(AxNavigation? target) {
    if (target == null) return false;
    switch (target.kind) {
      case AxRouteKind.home:
        return navigation.kind == AxRouteKind.home;
      case AxRouteKind.projects:
        return navigation.kind == AxRouteKind.projects ||
            navigation.kind == AxRouteKind.project ||
            navigation.kind == AxRouteKind.workstream ||
            navigation.kind == AxRouteKind.run;
      case AxRouteKind.project:
        return (navigation.kind == AxRouteKind.project ||
                navigation.kind == AxRouteKind.workstream ||
                navigation.kind == AxRouteKind.run) &&
            target.projectId != null &&
            navigation.projectId == target.projectId;
      case AxRouteKind.workstream:
        return navigation.kind == AxRouteKind.workstream &&
            target.workstreamId != null &&
            navigation.workstreamId == target.workstreamId;
      case AxRouteKind.workspaces:
        return navigation.kind == AxRouteKind.workspaces;
      case AxRouteKind.profileSecurity:
        return navigation.kind == AxRouteKind.profileSecurity;
      case AxRouteKind.run:
        return navigation.kind == AxRouteKind.run &&
            target.runId != null &&
            navigation.runId == target.runId;
      case AxRouteKind.login:
        return navigation.kind == AxRouteKind.login;
      case AxRouteKind.desktopAuthApproval:
        return false;
      case AxRouteKind.search:
        return navigation.kind == AxRouteKind.search;
    }
  }
}
