part of '../main.dart';

class _WorkersTab extends StatefulWidget {
  const _WorkersTab({
    required this.registry,
    required this.isSelected,
    this.catalogCoordinator,
    this.onRollbackToolProfile,
    this.onReadinessCheck,
    super.key,
  });

  final LocalWorkerRegistry? registry;
  final bool isSelected;
  final WorkerCatalogCoordinator? catalogCoordinator;
  final Future<bool> Function(String workerTypeId)? onRollbackToolProfile;
  final Future<void> Function(
      {LocalWorkerProbeMode mode, String? workerTypeId})? onReadinessCheck;

  @override
  State<_WorkersTab> createState() => _WorkersTabState();
}

class _WorkersTabState extends State<_WorkersTab> {
  final Set<String> _updatingWorkerTypes = {};
  bool _rollingBack = false;

  @override
  void initState() {
    super.initState();
    widget.catalogCoordinator?.addListener(_catalogChanged);
    if (widget.isSelected) {
      unawaited(
        widget.catalogCoordinator?.refresh(force: true) ?? Future<void>.value(),
      );
    }
  }

  @override
  void dispose() {
    widget.catalogCoordinator?.removeListener(_catalogChanged);
    super.dispose();
  }

  void _catalogChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _WorkersTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    var refreshCatalog = !oldWidget.isSelected && widget.isSelected;
    if (oldWidget.catalogCoordinator != widget.catalogCoordinator) {
      oldWidget.catalogCoordinator?.removeListener(_catalogChanged);
      widget.catalogCoordinator?.addListener(_catalogChanged);
      refreshCatalog = widget.isSelected;
    }
    if (refreshCatalog) {
      unawaited(
        widget.catalogCoordinator?.refresh(force: true) ?? Future<void>.value(),
      );
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
        unawaited(widget.catalogCoordinator?.refresh(force: true) ??
            Future<void>.value());
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
    await widget.catalogCoordinator?.refreshLocalWorkers();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Workers check their provider tools and report readiness to Workspace.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Refresh Worker catalog',
              onPressed: widget.catalogCoordinator == null
                  ? null
                  : () => unawaited(
                        widget.catalogCoordinator!.refresh(force: true),
                      ),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Builder(
          builder: (context) {
            final catalog = widget.catalogCoordinator?.snapshot ??
                const WorkerCatalogSnapshot();
            final canConfigure = widget.registry != null &&
                catalog.localRegistryLoaded &&
                catalog.localRegistryError == null;
            return Column(
              children: [
                for (final worker in catalog.workers)
                  if (worker.descriptor == null)
                    _buildRetiredWorkerCard(worker, theme)
                  else
                    _buildLogicalWorkerCard(worker, canConfigure, theme),
                if (catalog.descriptors.isEmpty && catalog.localRegistryLoaded)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'No Workers are available in the Cloud catalog.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (catalog.catalogError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: CopyableMessageText(
                      catalog.catalogError!,
                      style: TextStyle(color: theme.colorScheme.error),
                      iconColor: theme.colorScheme.error,
                    ),
                  ),
                if (catalog.localRegistryError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: CopyableMessageText(
                      catalog.localRegistryError!,
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
    WorkerCatalogWorkerState view,
    bool canConfigure,
    ThemeData theme,
  ) {
    final entry = view.descriptor;
    if (entry == null) return const SizedBox.shrink();
    final worker = view.localWorker;
    final profile = view.profileAvailability.details;
    final pending = _updatingWorkerTypes.contains(entry.workerTypeId);
    final readiness = pending ? 'Checking…' : view.readinessLabel;
    final badges = <String>{
      ...view.statusBadges(readinessLabelOverride: pending ? readiness : null),
      view.state.label,
      'Profile · ${view.profileState.label}',
    };
    final providerToolName = worker?.toolName ?? entry.providerToolName;
    final providerToolVersion = switch (view.providerToolState) {
      WorkspaceProviderToolState.unknown =>
        view.localState == WorkspaceLocalWorkerState.configured
            ? 'Not detected'
            : 'Unknown',
      WorkspaceProviderToolState.missing => 'Not installed',
      WorkspaceProviderToolState.available =>
        worker?.toolVersion ?? 'Available',
    };
    return Card(
      key: Key('worker-catalog-${entry.workerTypeId}'),
      margin: const EdgeInsets.only(bottom: 12),
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(Icons.smart_toy_outlined,
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
                        '$providerToolName · $providerToolVersion',
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
                  label: 'Catalog',
                  value: 'Available',
                ),
                _DetailRow(
                  label: 'Profile state',
                  value: view.profileState.label,
                ),
                _DetailRow(
                  label: 'Local Worker',
                  value: switch (view.localState) {
                    WorkspaceLocalWorkerState.loading => 'Loading',
                    WorkspaceLocalWorkerState.unavailable => 'Unavailable',
                    WorkspaceLocalWorkerState.notConfigured => 'Not configured',
                    WorkspaceLocalWorkerState.configured =>
                      worker?.id ?? 'Configured',
                  },
                ),
                _DetailRow(
                  label: 'Worker state',
                  value: view.state.label,
                ),
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
                if (view.profileAvailability.message != null)
                  _DetailRow(
                    label: 'Profile resolution detail',
                    value: view.profileAvailability.message!,
                  ),
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
                  value: providerToolVersion,
                ),
                _DetailRow(
                  label: 'Provider tool path (local only)',
                  value: worker?.toolPath ?? 'Not resolved',
                ),
                _DetailRow(
                  label: 'Readiness',
                  value: readiness,
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

  Widget _buildRetiredWorkerCard(
    WorkerCatalogWorkerState view,
    ThemeData theme,
  ) {
    final worker = view.localWorker!;
    final toolName = worker.toolName ?? 'Provider CLI';
    final toolVersion = switch (view.providerToolState) {
      WorkspaceProviderToolState.unknown => 'Not detected',
      WorkspaceProviderToolState.missing => 'Not installed',
      WorkspaceProviderToolState.available => worker.toolVersion ?? 'Available',
    };
    return Card(
      key: Key('retired-worker-${worker.workerTypeId}'),
      margin: const EdgeInsets.only(bottom: 12),
      color: theme.colorScheme.surfaceContainerLow,
      child: ListTile(
        leading: Icon(Icons.inventory_2_outlined,
            color: theme.colorScheme.onSurfaceVariant),
        title: Text(worker.workerTypeId,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _CatalogStatusBadge(label: view.state.label),
                _CatalogStatusBadge(label: view.readinessLabel),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('$toolName · $toolVersion',
                  style: theme.textTheme.bodySmall),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _configureCatalogWorker(WorkerDescriptor entry) async {
    await _runCatalogAction(entry, () async {
      final currentEntry = await _refreshCatalogEntry(entry);
      if (currentEntry == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('This Worker is no longer available in Cloud.'),
            ),
          );
        }
        return;
      }
      final registry = widget.registry;
      if (registry == null) return;
      await LocalWorkerSetupService(registry: registry).createCatalogWorker(
        entry: currentEntry,
        permissions: defaultLocalWorkerPermissions,
      );
      await widget.catalogCoordinator?.ensureWorkerProfileAvailable(
        entry.workerTypeId,
        waitForActiveRefresh: true,
      );
      await widget.onReadinessCheck?.call(
          mode: LocalWorkerProbeMode.live, workerTypeId: entry.workerTypeId);
    });
  }

  Future<void> _testCatalogWorker(WorkerDescriptor entry, LocalWorker worker) =>
      _runCatalogAction(entry, () async {
        final currentEntry = await _refreshCatalogEntry(entry);
        if (currentEntry == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('This Worker is no longer available in Cloud.'),
              ),
            );
          }
          return;
        }
        await widget.onReadinessCheck?.call(
          mode: LocalWorkerProbeMode.live,
          workerTypeId: worker.workerTypeId,
        );
      });

  Future<WorkerDescriptor?> _refreshCatalogEntry(WorkerDescriptor entry) async {
    final coordinator = widget.catalogCoordinator;
    if (coordinator == null) return entry;
    await coordinator.refresh(force: true);
    return coordinator.entryForWorker(entry.workerTypeId);
  }

  Future<void> _runCatalogAction(
      WorkerDescriptor entry, Future<void> Function() action) async {
    if (!_updatingWorkerTypes.add(entry.workerTypeId)) return;
    setState(() {});
    try {
      await action();
      await widget.catalogCoordinator?.refreshLocalWorkers();
      if (mounted) setState(() {});
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
}

class _CatalogStatusBadge extends StatelessWidget {
  const _CatalogStatusBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final color = switch (label) {
      'Ready' ||
      'Profile ready' ||
      'Profile · Available' =>
        ConclaveBrand.success,
      'Disabled' ||
      'Catalog retired' ||
      'Catalog unavailable' ||
      'Catalog available' ||
      'Profile · Resolving' =>
        Colors.grey,
      'Setup required' ||
      'Preparing integration…' ||
      'Authentication required' ||
      'Provider tool not installed' ||
      'Runtime unavailable' ||
      'Profile unavailable' ||
      'Incompatible' ||
      'Profile · Downloading' ||
      'Profile · Not downloaded' ||
      'Profile · Incompatible' =>
        ConclaveBrand.warning,
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
