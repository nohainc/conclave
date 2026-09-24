import 'app_sidebar.dart';

export 'app_menu.dart';
export 'app_sidebar.dart';
export 'project_tree.dart';

/// Backward-compatible subclass of [AppSidebar].
class StudioSidebar extends AppSidebar {
  const StudioSidebar({
    super.key,
    required super.shellContext,
    required super.onNavigateTo,
    required super.onToggleProjectExpanded,
    required super.onCreateProject,
    super.onCreateWorkstream,
    super.onToggleTheme,
    super.onSetThemeMode,
    required super.onLogout,
    required super.onOpenAbout,
    required super.onOpenExternal,
    super.compact = false,
  });
}

/// Backward-compatible subclass of [AppIconRail].
class StudioIconRail extends AppIconRail {
  const StudioIconRail({
    super.key,
    required super.shellContext,
    required super.onNavigateTo,
    required super.onOpenDrawer,
    super.onToggleTheme,
    super.onSetThemeMode,
    required super.onLogout,
    required super.onOpenAbout,
    required super.onOpenExternal,
  });
}
