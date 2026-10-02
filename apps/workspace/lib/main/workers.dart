part of '../main.dart';

class _WorkersTab extends StatefulWidget {
  const _WorkersTab({
    required this.registry,
    this.toolProfileCatalog,
    this.toolProfileReleaseStore,
    this.onRollbackToolProfile,
    this.onReadinessCheck,
    super.key,
  });

  final LocalWorkerRegistry? registry;
  final ToolProfileCatalogClient? toolProfileCatalog;
  final ToolProfileReleaseStore? toolProfileReleaseStore;
  final Future<bool> Function(String workerTypeId)? onRollbackToolProfile;
  final Future<void> Function(
      {LocalWorkerProbeMode mode, String? workerTypeId})? onReadinessCheck;

  @override
  State<_WorkersTab> createState() => _WorkersTabState();
}

class _WorkersTabState extends State<_WorkersTab> {
  Future<List<LocalWorker>>? _workers;
  final Set<String> _updatingWorkerTypes = {};
  List<LogicalWorkerCatalogEntry> _catalogEntries = const [];
  Map<String, Map<String, Object?>> _availableProfiles = {};
  bool _rollingBack = false;

  @override
  void initState() {
    super.initState();
    _loadWorkers();
    _loadLogicalWorkerCatalog();
  }

  Future<void> _loadLogicalWorkerCatalog() async {
    final catalog = widget.toolProfileCatalog;
    if (catalog == null) {
      if (mounted) {
        setState(() {
          _catalogEntries = const [];
          _availableProfiles = const {};
        });
      }
      return;
    }
    try {
      final cached = await catalog.loadCatalog();
      if (cached.isNotEmpty) {
        await _filterAvailableWorkers(cached);
      }
    } on Object {
      /* A malformed cache is ignored; the signed Cloud response is authoritative. */
    }
    try {
      final current = await catalog.syncCatalog();
      if (current.isNotEmpty) {
        await _filterAvailableWorkers(current);
      }
    } on Object {
      if (_catalogEntries.isEmpty) {
        await _filterAvailableWorkers(const []);
      }
    }
  }

  Future<void> _filterAvailableWorkers(
      List<LogicalWorkerCatalogEntry> entries) async {
    final store =
        widget.toolProfileReleaseStore ?? widget.toolProfileCatalog?.store;
    if (store == null) {
      if (mounted) {
        setState(() {
          _catalogEntries = const [];
          _availableProfiles = const {};
        });
      }
      return;
    }

    final workers = await widget.registry?.list() ?? const <LocalWorker>[];
    final availableEntries = <LogicalWorkerCatalogEntry>[];
    final availableProfiles = <String, Map<String, Object?>>{};

    for (final entry in entries) {
      final worker = workers
          .where((w) => w.workerTypeId == entry.workerTypeId)
          .firstOrNull;
      final profile = await _resolveWorkerProfile(entry, worker, store);
      if (profile != null) {
        availableEntries.add(entry);
        availableProfiles[entry.workerTypeId] = profile;
      }
    }

    if (mounted) {
      setState(() {
        _catalogEntries = availableEntries;
        _availableProfiles = availableProfiles;
      });
    }
  }

  Future<Map<String, Object?>?> _resolveWorkerProfile(
    LogicalWorkerCatalogEntry entry,
    LocalWorker? worker,
    ToolProfileReleaseStore store,
  ) async {
    final definitionId = entry.profileDefinitionId;
    try {
      final resolver = ToolProfileResolver(store);
      final profileState = await store.releaseState(definitionId);
      var resolution = worker?.toolVersion == null
          ? await resolver.resolveBootstrapProfile(
              logicalWorkerTypeId: entry.workerTypeId,
              profileDefinitionId: definitionId,
              engineVersion: cliWorkerEngineVersion,
              channel: profileState.selectedChannel,
            )
          : await resolver.resolve(
              logicalWorkerTypeId: entry.workerTypeId,
              profileDefinitionId: definitionId,
              engineVersion: cliWorkerEngineVersion,
              providerCliVersion: worker!.toolVersion!,
              channel: profileState.selectedChannel,
            );
      if (!resolution.isAvailable && worker?.toolVersion != null) {
        resolution = await resolver.resolveBootstrapProfile(
          logicalWorkerTypeId: entry.workerTypeId,
          profileDefinitionId: definitionId,
          engineVersion: cliWorkerEngineVersion,
          channel: profileState.selectedChannel,
        );
      }
      if (!resolution.isAvailable) {
        return null;
      }
      return {
        'displayName': entry.displayName,
        'definitionId': definitionId,
        'source': resolution.source.name,
        'activeVersion': profileState.activeVersion,
        'lastKnownGoodVersion': profileState.lastKnownGoodVersion,
        'channel': profileState.selectedChannel,
        if (resolution.release != null)
          'releaseVersion': resolution.release!.releaseVersion,
      };
    } on Object {
      return null;
    }
  }

  @override
  void didUpdateWidget(covariant _WorkersTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registry != widget.registry) _loadWorkers();
    if (oldWidget.toolProfileCatalog != widget.toolProfileCatalog ||
        oldWidget.toolProfileReleaseStore != widget.toolProfileReleaseStore) {
      unawaited(_loadLogicalWorkerCatalog());
    }
  }

  void _loadWorkers() {
    _workers = widget.registry?.list();
    if (widget.toolProfileCatalog != null) {
      unawaited(_loadLogicalWorkerCatalog());
    }
  }

  Future<void> _rollbackToolProfile(String workerTypeId) async {
    if (_rollingBack) return;
    setState(() => _rollingBack = true);
    var passed = false;
    try {
      passed = await widget.onRollbackToolProfile?.call(workerTypeId) ?? false;
    } on Object {
      passed = false;
    } finally {
      if (mounted) {
        setState(() {
          _rollingBack = false;
        });
        unawaited(_loadLogicalWorkerCatalog());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(passed
                ? 'Profile rollback passed its passive probe.'
                : 'Rollback validation failed. The current Profile was kept.'),
          ),
        );
      }
    }
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
                  _buildLogicalWorkerCard(
                    entry,
                    records,
                    canConfigure,
                    theme,
                    _availableProfiles[entry.workerTypeId],
                  ),
                if (_catalogEntries.isEmpty && snapshot.hasData)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'No available Workers with active profiles found.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
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
                      'Local Worker setup is unavailable. Restart Workspace and check Diagnostics.',
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
    Map<String, Object?>? profile,
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(_workerTypeIcon(entry.workerTypeId),
                color: theme.colorScheme.primary),
            title: Text(entry.displayName,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    for (final badge in badges)
                      _CatalogStatusBadge(label: badge)
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
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 16),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              leading: const Icon(Icons.analytics_outlined, size: 18),
              title: Text(
                'Diagnostics',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              children: [
                _DetailRow(
                  label: 'Workspace version',
                  value: conclaveWorkspaceAppVersion,
                ),
                _DetailRow(
                  label: 'Engine version',
                  value: cliWorkerEngineVersion,
                ),
                if (profile != null) ...[
                  _DetailRow(
                    label: 'Integration',
                    value:
                        '${profile['definitionId']}@${profile['releaseVersion'] ?? 'unavailable'}',
                  ),
                  _DetailRow(
                    label: 'Profile resolution',
                    value: '${profile['source']}',
                  ),
                  _DetailRow(
                    label: 'Profile channel',
                    value: '${profile['channel']}',
                  ),
                  _DetailRow(
                    label: 'Active Profile',
                    value: '${profile['activeVersion'] ?? 'None'}',
                  ),
                  _DetailRow(
                    label: 'Last-known-good Profile',
                    value: '${profile['lastKnownGoodVersion'] ?? 'None'}',
                  ),
                  if (profile['lastKnownGoodVersion'] is int)
                    Padding(
                      padding: const EdgeInsets.only(left: 138, top: 6),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _rollingBack ||
                                  widget.onRollbackToolProfile == null
                              ? null
                              : () => _rollbackToolProfile(entry.workerTypeId),
                          icon: _rollingBack
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.restore, size: 16),
                          label: Text(
                            'Validate and roll back to Profile ${profile['lastKnownGoodVersion']}',
                          ),
                        ),
                      ),
                    ),
                ],
                _DetailRow(
                  label: 'Worker Type ID',
                  value: entry.workerTypeId,
                ),
                _DetailRow(
                  label: 'Provider CLI',
                  value: worker?.toolName ?? entry.providerToolName,
                ),
                _DetailRow(
                  label: 'Provider CLI version',
                  value: worker?.toolVersion ?? 'Not detected',
                ),
                _DetailRow(
                  label: 'Provider tool path (local only)',
                  value: worker?.toolPath ?? 'Not resolved',
                ),
                _DetailRow(
                  label: 'Readiness',
                  value: worker == null
                      ? 'setup_required'
                      : '${worker.readinessState.wireValue}${worker.readinessIssueCode == null ? '' : ' · ${worker.readinessIssueCode}'}',
                ),
                _DetailRow(
                  label: 'Last Test',
                  value: _lastLiveTestLabel(worker),
                ),
                if (worker?.lastLiveTestDetails != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 138, bottom: 8),
                    child: CopyableMessageText(
                      worker!.lastLiveTestDetails!,
                      style: theme.textTheme.bodySmall,
                      tooltip: 'Copy Worker diagnostic',
                    ),
                  ),
              ],
            ),
          ),
        ],
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
            'Could not complete setup for ${entry.displayName}. Check Diagnostics.');
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
