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
  int _revision = 0;

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
            return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('Workspace: ${name ?? 'None selected'}',
                    key: const ValueKey('space-workspace-readonly'),
                    style:
                        TextStyle(color: theme.colorScheme.onSurfaceVariant)));
          }
          final known = settings.workspaces
              .any((workspace) => workspace.id == settings.workspaceId);
          final current = settings.inherited
              ? _followDefault
              : (settings.workspaceId ?? _followDefault);
          return Padding(
              padding: const EdgeInsets.only(top: 12),
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: KeyedSubtree(
                      key: ValueKey(_revision),
                      child: DropdownButtonFormField<String>(
                          key: const ValueKey('space-workspace'),
                          initialValue: current,
                          decoration: InputDecoration(
                              labelText: 'Workspace',
                              helperText: settings.inherited
                                  ? 'Following the default Workspace${name == null ? '' : ': $name'}'
                                  : 'Threads use this Workspace’s Workers and workflows'),
                          items: [
                            const DropdownMenuItem(
                                value: _followDefault,
                                child: Text('Default Workspace')),
                            for (final workspace in settings.workspaces)
                              DropdownMenuItem(
                                  value: workspace.id,
                                  child: Text(workspace.name)),
                            if (!settings.inherited &&
                                settings.workspaceId != null &&
                                !known)
                              DropdownMenuItem(
                                  value: settings.workspaceId,
                                  child: const Text('Unavailable Workspace')),
                          ],
                          onChanged: _busy
                              ? null
                              : (id) =>
                                  _select(id ?? _followDefault, current)))));
        },
      );

  Future<void> _select(String id, String current) async {
    if (id == current) return;
    final inherit = id == _followDefault;
    setState(() => _busy = true);
    try {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
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
                  ]));
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
        setState(() {
          _busy = false;
          _revision++;
        });
      }
    }
  }
}
