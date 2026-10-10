part of '../main.dart';

class _WorkersTab extends StatefulWidget {
  const _WorkersTab({
    required this.isSelected,
    this.catalogCoordinator,
    this.serviceAvailable = true,
    this.onReadinessCheck,
    this.onConfigureWorker,
    this.onSetWorkerEnabled,
    super.key,
  });

  final bool isSelected;
  final bool serviceAvailable;
  final WorkspaceWorkerCatalogClient? catalogCoordinator;
  final Future<void> Function(WorkerDescriptor worker)? onConfigureWorker;
  final Future<void> Function(String workerId, bool enabled)?
      onSetWorkerEnabled;
  final Future<void> Function(
      {LocalWorkerProbeMode mode, String? workerTypeId})? onReadinessCheck;

  @override
  State<_WorkersTab> createState() => _WorkersTabState();
}

class _WorkersTabState extends State<_WorkersTab> {
  final Set<String> _updatingWorkerTypes = {};
  @override
  void initState() {
    super.initState();
    widget.catalogCoordinator?.addListener(_catalogChanged);
    if (widget.isSelected && widget.serviceAvailable) {
      unawaited(
        widget.catalogCoordinator?.refresh() ?? Future<void>.value(),
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
    if (widget.serviceAvailable &&
        (refreshCatalog || !oldWidget.serviceAvailable && widget.isSelected)) {
      unawaited(
        widget.catalogCoordinator?.refresh() ?? Future<void>.value(),
      );
    }
  }

  Future<void> _setActivationState(
    LocalWorker worker,
    bool enabled,
  ) async {
    await widget.onSetWorkerEnabled?.call(worker.id, enabled);
    await widget.catalogCoordinator?.refreshLocalWorkers();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.serviceAvailable) ...[
            const Text(
                'Start the service to configure or test Workers. The last known Worker list is shown below.'),
            const SizedBox(height: 16),
          ],
          Builder(
            builder: (context) {
              final catalog = widget.catalogCoordinator?.snapshot ??
                  const WorkerCatalogSnapshot();
              final canConfigure = widget.onConfigureWorker != null &&
                  catalog.localRegistryLoaded &&
                  catalog.localRegistryError == null;
              return Column(
                children: [
                  for (final worker in catalog.workers)
                    if (worker.descriptor == null)
                      _buildRetiredWorkerCard(worker, theme)
                    else
                      _buildLogicalWorkerCard(worker, canConfigure, theme),
                  if (catalog.descriptors.isEmpty &&
                      catalog.localRegistryLoaded)
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
                  if (!catalog.localRegistryLoaded &&
                      catalog.localRegistryError != null)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: CopyableMessageText(
                        'Local Worker setup is unavailable. Restart Workspace and try again.',
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
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
    final pending = _updatingWorkerTypes.contains(entry.workerTypeId) ||
        !widget.serviceAvailable;
    final readiness = _updatingWorkerTypes.contains(entry.workerTypeId)
        ? 'Checking…'
        : view.readinessLabel;
    final badges = <String>{
      ...view.statusBadges(readinessLabelOverride: pending ? readiness : null),
      view.state.label,
      'Profile · ${view.profileState.label}',
      if (profile?['unsignedDevelopment'] == true)
        'Unsigned · Local development',
    };
    final providerToolName = worker?.toolName ?? entry.providerToolName;
    final providerToolVersion = switch (view.providerToolState) {
      WorkspaceProviderToolState.unknown =>
        view.profileState != WorkspaceWorkerProfileState.ready
            ? 'Waiting for Profile'
            : view.localState == WorkspaceLocalWorkerState.configured
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
                  if (worker != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Local Worker · ${worker.id}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ]),
            trailing: _updatingWorkerTypes.contains(entry.workerTypeId)
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
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Local Worker · ${worker.id}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
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
      await widget.onConfigureWorker?.call(currentEntry);
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
    await coordinator.refresh();
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
        showCopyableErrorSnackBar(
          context,
          'Could not complete setup for ${entry.displayName}. Try again or review the Worker status.',
        );
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
        ConclaveBrand.neutral,
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
