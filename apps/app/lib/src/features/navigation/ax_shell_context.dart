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
    required this.projects,
    this.projectWorkstreams,
    this.workstreamsByProject = const {},
    this.selectedProject,
    this.selectedWorkstream,
    this.selectedRun,
    this.workspaces = const [],
    this.unreadNotificationCount = 0,
    this.isDarkTheme = true,
    this.themeMode = ThemeMode.system,
    this.realtimeStale = false,
    this.realtimeNotice,
    this.viewerDisplayName,
    this.viewerEmail,
    this.expandedProjectIds = const {},
  });

  final AxNavigation navigation;
  final List<AxProject> projects;
  final AxProjectWorkstreams? projectWorkstreams;
  final Map<String, List<AxWorkstream>> workstreamsByProject;
  final AxProject? selectedProject;
  final AxWorkstream? selectedWorkstream;
  final AxRun? selectedRun;
  final List<AxWorkspace> workspaces;
  final int unreadNotificationCount;
  final bool isDarkTheme;
  final ThemeMode themeMode;
  final bool realtimeStale;
  final String? realtimeNotice;
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
