import '../../ax/sync/ax_query_builder.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../navigation/ax_navigation.dart';
import '../../ax/ax_models.dart';
import '../../ax/sync/ax_space_threads.dart';

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
    required List<AxSpace> spaces,
    this.spaceListenable,
    this.workspaceListenable,
    this.spaceThreads,
    this.threadsBySpace = const {},
    this.selectedSpace,
    this.selectedThread,
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
    this.expandedSpaceIds = const {},
  })  : _spaces = spaces,
        _workspaces = workspaces,
        _unreadNotificationCount = unreadNotificationCount,
        _realtimeStale = realtimeStale,
        _realtimeNotice = realtimeNotice;

  final AxNavigation navigation;
  final List<AxSpace> _spaces;
  final ValueListenable<List<AxSpace>>? spaceListenable;
  List<AxSpace> get spaces => spaceListenable?.value ?? _spaces;
  List<AxSpace> get ownedSpaces =>
      spaces.where((space) => space.role == 'owner').toList();
  List<AxSpace> get sharedSpaces =>
      spaces.where((space) => space.role != 'owner').toList();
  final AxSpaceThreads? spaceThreads;
  final Map<String, List<AxThread>> threadsBySpace;
  final AxSpace? selectedSpace;
  final AxThread? selectedThread;
  final AxRun? selectedRun;
  final List<AxWorkspace> _workspaces;
  final ValueListenable<List<AxWorkspace>>? workspaceListenable;
  List<AxWorkspace> get workspaces => workspaceListenable?.value ?? _workspaces;
  final int _unreadNotificationCount;
  final ValueListenable<int>? unreadNotifications;
  final ValueListenable<List<AxSpaceInvitation>>? invitationsListenable;
  List<AxSpaceInvitation> get invitations =>
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
        : ValueListenableBuilder<List<AxSpaceInvitation>>(
            valueListenable: listenable, builder: (context, _, __) => build());
  }

  Widget watchSpacesAndThreads(Widget Function() build) {
    Widget collections(int index) {
      final cache = spaceThreads;
      if (cache == null || index >= spaces.length) return build();
      return AxQueryBuilder<List<AxThread>>(
          engine: cache.engine,
          query: cache.query(spaces[index].id),
          ensure: false,
          builder: (context, _) => collections(index + 1));
    }

    final listenable = spaceListenable;
    return listenable == null
        ? collections(0)
        : ValueListenableBuilder<List<AxSpace>>(
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
  final Set<String> expandedSpaceIds;

  int get onlineWorkspaceCount =>
      workspaces.where((w) => w.status.toLowerCase() == 'online').length;

  AxWorkspace? get targetedWorkspace {
    final thread = selectedThread;
    if (thread != null &&
        thread.primaryWorkspace.isNotEmpty &&
        thread.primaryWorkspace != 'Not selected') {
      final query = thread.primaryWorkspace.trim().toLowerCase();
      return workspaces.where((w) {
        return w.name.trim().toLowerCase() == query ||
            w.id.trim().toLowerCase() == query ||
            w.hostname.trim().toLowerCase() == query;
      }).firstOrNull;
    }
    return null;
  }

  bool get isThreadContext =>
      selectedThread != null ||
      navigation.kind == AxRouteKind.thread ||
      navigation.kind == AxRouteKind.run;

  String get executionStatusLabel {
    if (isThreadContext) {
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
      final customName = selectedThread?.primaryWorkspace;
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
    if (isThreadContext) {
      final target = targetedWorkspace;
      if (target != null) {
        final st = target.status.toLowerCase();
        if (st == 'online') return ExecutionStatusTone.usable;
        if (st == 'degraded' || st == 'reconnecting') {
          return ExecutionStatusTone.degraded;
        }
        return ExecutionStatusTone.failed;
      }
      final customName = selectedThread?.primaryWorkspace;
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

  bool isSpaceExpanded(String spaceId) => expandedSpaceIds.contains(spaceId);

  bool isNavActive(AxNavigation? target) {
    if (target == null) return false;
    switch (target.kind) {
      case AxRouteKind.home:
        return navigation.kind == AxRouteKind.home;
      case AxRouteKind.spaces:
        return navigation.kind == AxRouteKind.spaces ||
            navigation.kind == AxRouteKind.space ||
            navigation.kind == AxRouteKind.thread ||
            navigation.kind == AxRouteKind.run;
      case AxRouteKind.space:
        return (navigation.kind == AxRouteKind.space ||
                navigation.kind == AxRouteKind.thread ||
                navigation.kind == AxRouteKind.run) &&
            target.spaceId != null &&
            navigation.spaceId == target.spaceId;
      case AxRouteKind.thread:
        return navigation.kind == AxRouteKind.thread &&
            target.threadId != null &&
            navigation.threadId == target.threadId;
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
