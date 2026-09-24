import 'app_top_hud.dart';

export 'app_top_hud.dart';
export 'breadcrumb.dart';
export 'execution_health.dart';

/// Backward-compatible subclass of [AppTopHud].
class StudioTopBar extends AppTopHud {
  const StudioTopBar({
    super.key,
    required super.shellContext,
    required super.onNavigateTo,
    required super.onOpenCommandPalette,
    required super.onOpenNotifications,
    super.searchController,
    super.searchFocusNode,
    super.onSearchChanged,
    super.onClearSearch,
    super.onToggleTheme,
    super.onOpenAbout,
    super.onLogout,
    super.onOpenExternal,
    super.compact = false,
  });
}
