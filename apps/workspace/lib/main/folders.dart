part of '../main.dart';

/// Sends one `folders.*` command to the Workspace Service.
typedef AllowedFolderCommand = Future<Object?> Function(
  String command, {
  Map<String, Object?> payload,
});

/// Owner-managed folders outside Work Root that Spaces on this Workspace may
/// use. The service validates and probes every folder; this card only lists
/// them and forwards the owner's choices.
class AllowedFoldersCard extends StatefulWidget {
  const AllowedFoldersCard({
    this.command,
    this.chooseDirectory,
    this.requireStepUp,
    this.serviceAvailable = true,
    super.key,
  });

  final AllowedFolderCommand? command;
  final Future<String?> Function()? chooseDirectory;
  final Future<bool> Function(String reason)? requireStepUp;
  final bool serviceAvailable;

  @override
  State<AllowedFoldersCard> createState() => _AllowedFoldersCardState();
}

class _AllowedFoldersCardState extends State<AllowedFoldersCard> {
  List<Map<String, Object?>>? _folders;
  String? _error;
  bool _busy = false;

  bool get _enabled =>
      widget.serviceAvailable && widget.command != null && !_busy;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant AllowedFoldersCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serviceAvailable && !oldWidget.serviceAvailable) {
      unawaited(_load());
    }
  }

  Future<void> _load() =>
      _run('folders.list', failure: 'Could not read allowed folders');

  Future<void> _run(
    String command, {
    Map<String, Object?> payload = const {},
    required String failure,
    bool reload = false,
  }) async {
    final send = widget.command;
    if (send == null || !widget.serviceAvailable) return;
    setState(() => _busy = true);
    try {
      var result = await send(command, payload: payload);
      if (reload) result = await send('folders.list');
      if (!mounted) return;
      setState(() {
        if (result is Map && result['folders'] is List) {
          _folders = [
            for (final entry in result['folders'] as List)
              if (entry is Map) Map<String, Object?>.from(entry),
          ];
        }
        _error = null;
      });
    } on WorkspaceManagerProtocolException catch (error) {
      if (mounted) setState(() => _error = '$failure: ${error.message}');
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$failure: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final choose = widget.chooseDirectory;
    if (choose == null) return;
    final path = await choose();
    if (path == null || path.isEmpty || !mounted) return;
    final stepUp = widget.requireStepUp;
    if (stepUp != null &&
        !await stepUp('Allow AI Workers to use a folder on this computer')) {
      return;
    }
    await _run('folders.add',
        payload: {'path': path},
        failure: 'Could not allow folder',
        reload: true);
  }

  Future<void> _remove(Map<String, Object?> folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove allowed folder?'),
        content: Text(
          'Spaces will no longer be able to use "${folder['displayName']}". '
          'The folder and its files stay on this computer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run('folders.remove',
        payload: {'folderId': folder['id']},
        failure: 'Could not remove folder',
        reload: true);
  }

  static String _statusLabel(Object? status) => switch (status) {
        'available' => 'Read & write',
        'read_only' => 'Read only',
        'denied' => 'No access',
        _ => 'Missing',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folders = _folders;
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          border:
              Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text('Allowed folders',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w400)),
              ),
              if (folders != null && folders.isNotEmpty)
                TextButton(
                  key: const ValueKey('allowed-folders-recheck'),
                  onPressed: _enabled
                      ? () => _run('folders.recheck',
                          failure: 'Could not check folders')
                      : null,
                  child: const Text('Check access'),
                ),
              TextButton.icon(
                key: const ValueKey('allowed-folders-add'),
                onPressed:
                    _enabled && widget.chooseDirectory != null ? _add : null,
                icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                label: const Text('Add folder'),
              ),
            ]),
            Text(
              'Folders outside Work Root that your Spaces may use. Only you '
              'can add them; files are never moved or deleted.',
              style: muted,
            ),
            const SizedBox(height: 8),
            if (folders == null)
              Text(
                widget.serviceAvailable
                    ? 'Reading folders…'
                    : 'Start the service to manage allowed folders.',
                style: theme.textTheme.bodyMedium,
              )
            else if (folders.isEmpty)
              Text('No folders allowed.',
                  key: const ValueKey('allowed-folders-empty'),
                  style: theme.textTheme.bodyMedium)
            else
              for (final folder in folders)
                ListTile(
                  key: ValueKey('allowed-folder-${folder['id']}'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    folder['status'] == 'available' ||
                            folder['status'] == 'read_only'
                        ? Icons.folder_outlined
                        : Icons.folder_off_outlined,
                    color: folder['status'] == 'available' ||
                            folder['status'] == 'read_only'
                        ? null
                        : theme.colorScheme.error,
                  ),
                  title: Text('${folder['displayName']}'),
                  subtitle: Text(
                    '${folder['path']} · ${_statusLabel(folder['status'])}',
                    style: muted,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: _enabled ? () => _remove(folder) : null,
                  ),
                ),
            if (_error != null && widget.serviceAvailable)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: CopyableMessageText(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                  iconColor: theme.colorScheme.error,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
