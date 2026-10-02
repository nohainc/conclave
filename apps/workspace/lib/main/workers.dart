part of '../main.dart';

class _WorkersTab extends StatefulWidget {
  const _WorkersTab({
    required this.registry,
    this.toolProfileCatalog,
    this.onReadinessCheck,
    super.key,
  });

  final LocalWorkerRegistry? registry;
  final ToolProfileCatalogClient? toolProfileCatalog;
  final Future<void> Function(
      {LocalWorkerProbeMode mode, String? workerTypeId})? onReadinessCheck;

  @override
  State<_WorkersTab> createState() => _WorkersTabState();
}

class _WorkersTabState extends State<_WorkersTab> {
  Future<List<LocalWorker>>? _workers;
  final Set<String> _updatingWorkerTypes = {};
  List<LogicalWorkerCatalogEntry> _catalogEntries = const [];

  @override
  void initState() {
    super.initState();
    _loadWorkers();
    _loadLogicalWorkerCatalog();
  }

  Future<void> _loadLogicalWorkerCatalog() async {
    final catalog = widget.toolProfileCatalog;
    if (catalog == null) {
      if (mounted) setState(() => _catalogEntries = const []);
      return;
    }
    try {
      final cached = await catalog.loadCatalog();
      if (mounted && cached.isNotEmpty) {
        setState(() => _catalogEntries = cached);
      }
    } on Object {
      /* A malformed cache is ignored; the signed Cloud response is authoritative. */
    }
    try {
      final current = await catalog.syncCatalog();
      if (mounted) setState(() => _catalogEntries = current);
    } on Object {
      if (mounted && _catalogEntries.isEmpty) {
        setState(() => _catalogEntries = const []);
      }
    }
  }

  @override
  void didUpdateWidget(covariant _WorkersTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registry != widget.registry) _loadWorkers();
    if (oldWidget.toolProfileCatalog != widget.toolProfileCatalog) {
      unawaited(_loadLogicalWorkerCatalog());
    }
  }

  void _loadWorkers() {
    _workers = widget.registry?.list();
  }

  Future<void> _setActivationState(
    LocalWorker worker,
    bool enabled,
  ) async {
    final registry = widget.registry;
    if (registry == null) return;
    await registry.update(
      worker.id,
      (current) => current.copyWith(
        status: enabled
            ? LocalWorkerStatus.needsAttention
            : LocalWorkerStatus.disabled,
        activationState: enabled
            ? LocalWorkerActivationState.enabled
            : LocalWorkerActivationState.disabled,
      ),
    );
    if (enabled) {
      await widget.onReadinessCheck?.call(
        mode: LocalWorkerProbeMode.passive,
        workerTypeId: worker.workerTypeId,
      );
    }
    if (mounted) setState(_loadWorkers);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Workers check their provider tools and report readiness to Workspace.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        FutureBuilder<List<LocalWorker>>(
          future: _workers,
          builder: (context, snapshot) {
            final records = snapshot.data ?? const <LocalWorker>[];
            final canConfigure = widget.registry != null && snapshot.hasData;
            return Column(
              children: [
                for (final entry in _catalogEntries)
                  _buildLogicalWorkerCard(entry, records, canConfigure, theme),
                if (snapshot.hasError)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: CopyableMessageText(
                      'Worker status could not be loaded: ${snapshot.error}',
                      style: TextStyle(color: theme.colorScheme.error),
                      iconColor: theme.colorScheme.error,
                    ),
                  ),
                if (widget.registry == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: CopyableMessageText(
                      'Local Worker setup is unavailable. Restart Workspace and check Advanced Diagnostics.',
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildLogicalWorkerCard(
    LogicalWorkerCatalogEntry entry,
    List<LocalWorker> records,
    bool canConfigure,
    ThemeData theme,
  ) {
    final worker = records
        .where((record) => record.workerTypeId == entry.workerTypeId)
        .firstOrNull;
    final pending = _updatingWorkerTypes.contains(entry.workerTypeId);
    final readiness = pending
        ? 'Checking…'
        : worker == null
            ? 'Setup required'
            : deriveLocalWorkerReadiness(worker);
    final badges = worker == null
        ? <String>[readiness]
        : deriveLocalWorkerStatusBadges(worker,
            readinessLabel: pending ? readiness : null);
    final providerToolName = worker?.toolName ?? entry.providerToolName;
    final providerToolLabel =
        providerToolName == 'codex' ? 'Codex CLI' : providerToolName;
    return Card(
      key: Key('worker-catalog-${entry.workerTypeId}'),
      margin: const EdgeInsets.only(bottom: 12),
      color: theme.colorScheme.surfaceContainerLow,
      child: ListTile(
        leading: Icon(_workerTypeIcon(entry.workerTypeId),
            color: theme.colorScheme.primary),
        title: Text(entry.displayName,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final badge in badges) _CatalogStatusBadge(label: badge)
              ]),
              Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    '$providerToolLabel ${worker?.toolVersion ?? 'version not detected'}',
                    style: theme.textTheme.bodySmall,
                  )),
            ]),
        trailing: pending
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
            : worker == null
                ? TextButton(
                    onPressed: canConfigure
                        ? () => _configureCatalogWorker(entry)
                        : null,
                    child: const Text('Configure'))
                : Wrap(
                    spacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                        TextButton(
                            onPressed: canConfigure
                                ? () => _testCatalogWorker(entry, worker)
                                : null,
                            child: const Text('Test')),
                        Tooltip(
                            message: worker.activationState ==
                                    LocalWorkerActivationState.enabled
                                ? 'Disable'
                                : 'Enable',
                            child: Switch(
                              value: worker.activationState ==
                                  LocalWorkerActivationState.enabled,
                              onChanged: canConfigure
                                  ? (enabled) =>
                                      _setActivationState(worker, enabled)
                                  : null,
                            )),
                      ]),
      ),
    );
  }

  Future<void> _configureCatalogWorker(LogicalWorkerCatalogEntry entry) async {
    await _runCatalogAction(entry, () async {
      final registry = widget.registry;
      if (registry == null) return;
      await LocalWorkerSetupService(registry: registry).createCatalogWorker(
        entry: entry,
        permissions: permissionsForLogicalWorker(entry.capabilities),
      );
      await widget.toolProfileCatalog?.syncWorkerProfiles(entry.workerTypeId);
      await widget.onReadinessCheck?.call(
          mode: LocalWorkerProbeMode.live, workerTypeId: entry.workerTypeId);
    });
  }

  Future<void> _testCatalogWorker(
          LogicalWorkerCatalogEntry entry, LocalWorker worker) =>
      _runCatalogAction(
          entry,
          () =>
              widget.onReadinessCheck?.call(
                mode: LocalWorkerProbeMode.live,
                workerTypeId: worker.workerTypeId,
              ) ??
              Future<void>.value());

  Future<void> _runCatalogAction(
      LogicalWorkerCatalogEntry entry, Future<void> Function() action) async {
    if (!_updatingWorkerTypes.add(entry.workerTypeId)) return;
    setState(() {});
    try {
      await action();
      if (mounted) setState(_loadWorkers);
    } on Object {
      if (mounted) {
        showCopyableErrorSnackBar(context,
            'Could not complete setup for ${entry.displayName}. Check Advanced Diagnostics.');
      }
    } finally {
      _updatingWorkerTypes.remove(entry.workerTypeId);
      if (mounted) setState(() {});
    }
  }

  static IconData _workerTypeIcon(String id) => switch (id) {
        'chatgpt' => Icons.terminal,
        'gemini' => Icons.auto_awesome,
        _ => Icons.smart_toy_outlined,
      };
}

class _CatalogStatusBadge extends StatelessWidget {
  const _CatalogStatusBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final color = switch (label) {
      'Ready' => ConclaveBrand.success,
      'Disabled' => Colors.grey,
      'Setup required' || 'Not installed' => ConclaveBrand.warning,
      _ => ConclaveBrand.error,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

String deriveLocalWorkerHealth(LocalWorker worker) {
  if (worker.activationState == LocalWorkerActivationState.disabled) {
    return 'Disabled';
  }
  return deriveLocalWorkerReadiness(worker);
}

List<String> deriveLocalWorkerStatusBadges(
  LocalWorker worker, {
  String? readinessLabel,
}) =>
    [
      if (worker.activationState == LocalWorkerActivationState.disabled)
        'Disabled',
      readinessLabel ?? deriveLocalWorkerReadiness(worker),
    ];

String deriveLocalWorkerReadiness(LocalWorker worker) {
  if (worker.lastLiveTestPassed == false) {
    final liveIssue = worker.lastLiveTestIssueCode ?? worker.readinessIssueCode;
    if (liveIssue == 'cli_not_found') return 'Not installed';
    if (liveIssue == 'setup_required' ||
        liveIssue == 'authentication_required') {
      return 'Setup required';
    }
    return 'Needs attention';
  }
  if (worker.readinessState == WorkerReadinessState.setupRequired &&
      worker.lastLiveTestPassed == true) {
    return 'Ready';
  }
  final issueCode = worker.readinessIssueCode;
  if (issueCode == 'cli_not_found') return 'Not installed';
  if (worker.readinessState == WorkerReadinessState.ready) return 'Ready';
  if (issueCode == 'setup_required' ||
      issueCode == 'authentication_required' ||
      worker.readinessState == WorkerReadinessState.setupRequired ||
      worker.readinessState == WorkerReadinessState.signInRequired) {
    return 'Setup required';
  }
  return 'Needs attention';
}

String _lastLiveTestLabel(LocalWorker? worker) {
  final testedAt = worker?.lastLiveTestAt;
  if (testedAt == null) return 'Not run';
  final date = DateTime.tryParse(testedAt)?.toLocal();
  final when = date == null ? testedAt : date.toString().split('.').first;
  final result = worker?.lastLiveTestPassed == true ? 'Passed' : 'Failed';
  return '$result · $when';
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyableDetailRow extends StatelessWidget {
  const _CopyableDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 14),
            tooltip: 'Copy $label',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('$label copied to clipboard'),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _WorkspaceRecoveryPanel extends StatelessWidget {
  const _WorkspaceRecoveryPanel({
    this.issue,
    required this.retryLabel,
    this.onRetry,
  });

  final String? issue;
  final String retryLabel;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.errorContainer.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('What happened',
              style: TextStyle(
                  color: colors.onErrorContainer, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          CopyableMessageText(
            issue ?? 'The Workspace needs attention.',
            style: TextStyle(color: colors.onErrorContainer),
            iconColor: colors.onErrorContainer,
            tooltip: 'Copy error message',
          ),
          const SizedBox(height: 8),
          Text(
              'Your work is safe. The Workspace will not discard an assignment.',
              style: TextStyle(color: colors.onErrorContainer)),
          const SizedBox(height: 4),
          Text(
              '$retryLabel is available. Automatic retry depends on the error.',
              style: TextStyle(color: colors.onErrorContainer)),
          if (onRetry != null) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () => unawaited(onRetry!()),
              icon: const Icon(Icons.refresh),
              label: Text(retryLabel),
            ),
          ],
        ],
      ),
    );
  }
}
