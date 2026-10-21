part of '../spaces_pages.dart';

/// Which Workspace a Space runs on. Threads use that Workspace's Workers and
/// workflows. Owners can pick one of their Workspaces or follow the default;
/// other members only see the current choice.
class _SpaceWorkspaceSelector extends StatefulWidget {
  const _SpaceWorkspaceSelector(
      {required this.configurations, required this.isOwner});
  final AxWorkflowConfigurations configurations;
  final bool isOwner;

  @override
  State<_SpaceWorkspaceSelector> createState() =>
      _SpaceWorkspaceSelectorState();
}

class _SpaceWorkspaceSelectorState extends State<_SpaceWorkspaceSelector> {
  static const _followDefault = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _ensure();
  }

  @override
  void didUpdateWidget(_SpaceWorkspaceSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.configurations != widget.configurations) _ensure();
  }

  void _ensure() => unawaited(widget.configurations
      .ensureWorkspace()
      .then<void>((_) {}, onError: (Object _, StackTrace __) {}));

  @override
  Widget build(BuildContext context) => AxQueryBuilder(
        engine: widget.configurations.engine,
        query: widget.configurations.workspaceQuery,
        ensure: false,
        builder: (context, state) {
          final settings = state.data;
          if (settings == null) return const SizedBox.shrink();
          final name = settings.workspaces
              .where((workspace) => workspace.id == settings.workspaceId)
              .firstOrNull
              ?.name;
          final theme = Theme.of(context);
          if (!widget.isOwner) {
            return Text('Workspace: ${name ?? 'None selected'}',
                key: const ValueKey('space-workspace-readonly'),
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant));
          }
          final known = settings.workspaces
              .any((workspace) => workspace.id == settings.workspaceId);
          final current = settings.inherited
              ? _followDefault
              : (settings.workspaceId ?? _followDefault);
          final choices = <String, String>{
            _followDefault: 'Default Workspace',
            for (final workspace in settings.workspaces)
              workspace.id: workspace.name,
            if (!settings.inherited && settings.workspaceId != null && !known)
              settings.workspaceId!: 'Unavailable Workspace',
          };
          final isDark = theme.brightness == Brightness.dark;
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('Workspace',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(width: 8),
                  // Same compact list selector as the Work composer and
                  // workflow model pickers.
                  PopupMenuButton<String>(
                    key: const ValueKey('space-workspace'),
                    enabled: !_busy,
                    tooltip: 'Choose Workspace',
                    color: ConclaveColors.composerBackground(isDark),
                    surfaceTintColor: Colors.transparent,
                    elevation: 12,
                    shadowColor: ConclaveMenuStyle.shadow(isDark),
                    shape: ConclaveMenuStyle.shape(isDark),
                    menuPadding: ConclaveMenuStyle.padding,
                    itemBuilder: (menuContext) => [
                      for (final choice in choices.entries)
                        ConclaveMenuEntry<String>(
                          value: choice.key,
                          child: MenuItemButton(
                            style: ConclaveMenuStyle.item(isDark),
                            leadingIcon: Icon(
                              choice.key == current
                                  ? Icons.check_circle_rounded
                                  : Icons.circle_outlined,
                              size: 15,
                            ),
                            onPressed: () =>
                                Navigator.pop(menuContext, choice.key),
                            child: Text(choice.value,
                                style: ConclaveMenuStyle.textStyle),
                          ),
                        ),
                    ],
                    onSelected: (id) => _select(id, current, settings),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 5),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(choices[current] ?? 'Default Workspace',
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(width: 2),
                        const Icon(Icons.keyboard_arrow_down, size: 14),
                      ]),
                    ),
                  ),
                ]),
                if (settings.inherited)
                  Text(
                      'Following the default Workspace${name == null ? '' : ': $name'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
              ]);
        },
      );

  Future<void> _select(
      String id, String current, AxWorkflowWorkspaceSettings settings) async {
    if (id == current) return;
    final inherit = id == _followDefault;
    setState(() => _busy = true);
    try {
      final targetWorkspace = inherit
          ? (await widget.configurations.engine.refresh(
                  AxWorkflowConfigurations(widget.configurations.source,
                          engine: widget.configurations.engine)
                      .workspaceQuery))
              .workspaceId
          : id;
      if (!mounted) return;
      final sameWorkspace = targetWorkspace == settings.workspaceId;
      final confirmed = sameWorkspace ||
          (await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                          constraints: ConclaveDialogStyle.small,
                          title: const Text('Change Workspace?'),
                          content: Text(inherit
                              ? 'This Space will follow your default Workspace. Its own workflow overrides are reset, and existing runs keep their recorded settings.'
                              : 'Threads in this Space will use the Workers and workflows of the selected Workspace. This Space’s workflow overrides are reset, the Workspace is authorized to run Work here, and existing runs keep their recorded settings.'),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel')),
                            FilledButton(
                                key: const ValueKey('confirm-space-workspace'),
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Change Workspace')),
                          ]))) ==
              true;
      if (confirmed != true || !mounted) return;
      await widget.configurations
          .selectWorkspace(inherit ? null : id, inherit: inherit);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showNotice(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }
}
