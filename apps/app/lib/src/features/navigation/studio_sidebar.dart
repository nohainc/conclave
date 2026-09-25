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
    super.searchController,
    super.searchFocusNode,
    super.onSearchChanged,
    super.onClearSearch,
    super.onOpenCommandPalette,
    super.onOpenNotifications,
    super.onToggleTheme,
    super.onSetThemeMode,
    required super.onLogout,
    required super.onOpenAbout,
    required super.onOpenExternal,
    super.onToggleCollapse,
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
    super.onCreateProject,
    super.onCreateWorkstream,
    super.searchController,
    super.searchFocusNode,
    super.onSearchChanged,
    super.onClearSearch,
    super.onOpenCommandPalette,
    super.onOpenNotifications,
    super.onToggleTheme,
    super.onSetThemeMode,
    required super.onLogout,
    required super.onOpenAbout,
    required super.onOpenExternal,
    super.onToggleCollapse,
  });
}
