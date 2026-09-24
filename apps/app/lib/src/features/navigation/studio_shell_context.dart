import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../navigation/studio_navigation.dart';
import '../../studio/studio_models.dart';

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
    this.themeMode = ThemeMode.system,
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
  final ThemeMode themeMode;
  final bool realtimeStale;
  final String? realtimeNotice;
  final String? viewerDisplayName;
  final String? viewerEmail;
  final Set<String> expandedProjectIds;

  int get onlineWorkspaceCount =>
      workspaces.where((w) => w.status.toLowerCase() == 'online').length;

  StudioAgent? get targetedWorkspace {
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
      navigation.kind == StudioRouteKind.workstream ||
      navigation.kind == StudioRouteKind.run;

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

  bool isNavActive(StudioNavigation? target) {
    if (target == null) return false;
    switch (target.kind) {
      case StudioRouteKind.home:
        return navigation.kind == StudioRouteKind.home;
      case StudioRouteKind.projects:
        return navigation.kind == StudioRouteKind.projects ||
            navigation.kind == StudioRouteKind.project ||
            navigation.kind == StudioRouteKind.workstream ||
            navigation.kind == StudioRouteKind.run ||
            navigation.kind == StudioRouteKind.chat;
      case StudioRouteKind.project:
        return (navigation.kind == StudioRouteKind.project ||
                navigation.kind == StudioRouteKind.workstream ||
                navigation.kind == StudioRouteKind.run ||
                navigation.kind == StudioRouteKind.chat) &&
            target.projectId != null &&
            navigation.projectId == target.projectId;
      case StudioRouteKind.workstream:
        return navigation.kind == StudioRouteKind.workstream &&
            target.workstreamId != null &&
            navigation.workstreamId == target.workstreamId;
      case StudioRouteKind.hosts:
        return navigation.kind == StudioRouteKind.hosts ||
            navigation.kind == StudioRouteKind.workers ||
            navigation.kind == StudioRouteKind.accounts;
      case StudioRouteKind.workers:
        return navigation.kind == StudioRouteKind.workers;
      case StudioRouteKind.accounts:
        return navigation.kind == StudioRouteKind.accounts;
      case StudioRouteKind.usage:
        return navigation.kind == StudioRouteKind.usage;
      case StudioRouteKind.profileSecurity:
        return navigation.kind == StudioRouteKind.profileSecurity;
      case StudioRouteKind.run:
        return navigation.kind == StudioRouteKind.run &&
            target.runId != null &&
            navigation.runId == target.runId;
      case StudioRouteKind.chat:
        return navigation.kind == StudioRouteKind.chat &&
            target.chatId != null &&
            navigation.chatId == target.chatId;
      case StudioRouteKind.login:
        return navigation.kind == StudioRouteKind.login;
    }
  }
}
