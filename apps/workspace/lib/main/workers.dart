part of '../main.dart';

class _WorkersTab extends StatefulWidget {
  const _WorkersTab({
    required this.isSelected,
    this.catalogCoordinator,
    this.serviceAvailable = true,
    this.onReadinessCheck,
    this.onLoadSlots,
    this.onResetSlots,
    this.onSetParallelSlots,
    this.onConfigureWorker,
    this.onSetWorkerEnabled,
    this.onSetFullLocalAccess,
    this.requireStepUp,
    super.key,
  });

  final bool isSelected;
  final bool serviceAvailable;
  final WorkspaceWorkerCatalogClient? catalogCoordinator;
  final Future<void> Function(WorkerDescriptor worker)? onConfigureWorker;
  final Future<void> Function(String workerId, bool enabled)?
      onSetWorkerEnabled;
  final Future<void> Function(String workerId, bool enabled)?
      onSetFullLocalAccess;
  final Future<bool> Function(String reason)? requireStepUp;
  final Future<void> Function(
      {LocalWorkerProbeMode mode, String? workerTypeId})? onReadinessCheck;
  final Future<Map<String, Object?>> Function()? onLoadSlots;
  final Future<Map<String, Object?>> Function()? onResetSlots;
  final Future<Map<String, Object?>> Function(int slots)? onSetParallelSlots;

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

  Future<void> _setFullLocalAccess(
    LocalWorker worker,
    bool enabled,
  ) async {
    if (enabled && widget.requireStepUp != null) {
      final authenticated = await widget.requireStepUp!(
        'Authorize Full Local Access for this Worker',
      );
      if (!authenticated) return;
    }
    await widget.onSetFullLocalAccess?.call(worker.id, enabled);
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
          if (widget.onLoadSlots != null && widget.serviceAvailable)
            _WorkerSlotsCard(
              load: widget.onLoadSlots!,
              reset: widget.onResetSlots,
              setSlots: widget.onSetParallelSlots,
            ),
          Builder(
            builder: (context) {
              final catalog = widget.catalogCoordinator?.snapshot ??
                  const WorkerCatalogSnapshot();
              final canConfigure = !catalog.refreshing &&
                  widget.onConfigureWorker != null &&
                  catalog.localRegistryLoaded &&
                  catalog.localRegistryError == null;
              return Column(
                children: [
                  if (catalog.refreshing)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const LinearProgressIndicator(
                              semanticsLabel: 'Refreshing Worker catalog'),
                          const SizedBox(height: 6),
                          Text(
                            'Refreshing Worker catalog, Profiles, and models…',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
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
    final catalogRefreshing =
        widget.catalogCoordinator?.snapshot.refreshing == true;
    final pending = catalogRefreshing ||
        _updatingWorkerTypes.contains(entry.workerTypeId) ||
        !widget.serviceAvailable;
    final readiness = _updatingWorkerTypes.contains(entry.workerTypeId)
        ? catalogRefreshing
            ? 'Refreshing…'
            : 'Checking…'
        : view.readinessLabel;
    final ready = !pending && readiness == 'Ready';
    final disabled =
        worker?.activationState == LocalWorkerActivationState.disabled;
    final badges = pending
        ? <String>[readiness]
        : ready
            ? <String>['Ready', if (disabled) 'Disabled']
            : <String>{
                ...view.statusBadges(),
                view.state.label,
              }.toList();
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
    final profileRevision = profile?['revision'] ?? profile?['releaseVersion'];
    final profileStatus = _profileStatusLabel(view, pending: pending);
    final workerState = worker == null
        ? 'Not configured'
        : disabled
            ? 'Disabled'
            : 'Enabled';
    final readinessStatus = pending
        ? readiness
        : ready
            ? 'Ready'
            : 'Needs attention';
    final staticModelNames =
        (profile?['staticModelNames'] as List?)?.whereType<String>().toList() ??
            const <String>[];
    final availableModels = profile?['hasModelDiscovery'] == false
        ? staticModelNames
        : worker?.modelCatalog?.models
                .where((model) => model.status != 'unavailable')
                .map((model) => model.name)
                .toList() ??
            staticModelNames;
    return Card(
      key: Key('worker-catalog-${entry.workerTypeId}'),
      margin: const EdgeInsets.only(bottom: 12),
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(entry.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      for (final badge in badges)
                        _CatalogStatusBadge(label: badge),
                    ],
                  ),
                ),
                if (_updatingWorkerTypes.contains(entry.workerTypeId))
                  const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else if (worker == null)
                  TextButton(
                      onPressed: canConfigure
                          ? () => _configureCatalogWorker(entry)
                          : null,
                      child: const Text('Configure'))
                else ...[
                  TextButton(
                      onPressed: canConfigure
                          ? () => _testCatalogWorker(entry, worker)
                          : null,
                      child: const Text('Test')),
                  TextButton(
                      onPressed: canConfigure
                          ? () => _setActivationState(
                              worker,
                              worker.activationState !=
                                  LocalWorkerActivationState.enabled)
                          : null,
                      child: Text(worker.activationState ==
                              LocalWorkerActivationState.enabled
                          ? 'Disable'
                          : 'Enable')),
                  TextButton(
                    onPressed:
                        canConfigure && widget.onSetFullLocalAccess != null
                            ? () => _setFullLocalAccess(
                                  worker,
                                  !worker.fullLocalAccessAuthorized,
                                )
                            : null,
                    child: Text(worker.fullLocalAccessAuthorized
                        ? 'Disable full access'
                        : 'Enable full access'),
                  ),
                ],
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text('Provider tool: $providerToolName',
                      style: theme.textTheme.bodySmall),
                ),
                Text('Installed CLI version: $providerToolVersion',
                    style: theme.textTheme.bodySmall),
                if (profileRevision != null)
                  Text('Profile revision: $profileRevision',
                      style: theme.textTheme.bodySmall),
                Text('Profile status: $profileStatus',
                    style: theme.textTheme.bodySmall),
                Text('Worker state: $workerState',
                    style: theme.textTheme.bodySmall),
                Text('Readiness: $readinessStatus',
                    style: theme.textTheme.bodySmall),
                if (worker != null)
                  Text(
                      'Execution permissions: ${worker.fullLocalAccessAuthorized ? 'Full local access' : 'Restricted'}',
                      style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          if (worker != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      'Models: ${availableModels.isEmpty ? 'Unavailable' : availableModels.join(', ')}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _profileStatusLabel(
    WorkerCatalogWorkerState view, {
    required bool pending,
  }) {
    if (pending) return 'Checking…';
    return switch (view.profileState) {
      WorkspaceWorkerProfileState.ready =>
        view.profileAvailability.details?['source'] == 'lastKnownGood'
            ? 'Update available'
            : 'Current',
      WorkspaceWorkerProfileState.incompatible => 'Incompatible',
      WorkspaceWorkerProfileState.resolving ||
      WorkspaceWorkerProfileState.syncing =>
        'Checking…',
      WorkspaceWorkerProfileState.unavailable ||
      WorkspaceWorkerProfileState.error =>
        'Update available',
    };
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


/// Shows the shared parallel execution slots in use and lets the user reset them when
/// work was abandoned (for example during a disconnect) and slots stay busy.
class _WorkerSlotsCard extends StatefulWidget {
  const _WorkerSlotsCard({required this.load, this.reset, this.setSlots});

  final Future<Map<String, Object?>> Function() load;
  final Future<Map<String, Object?>> Function()? reset;
  final Future<Map<String, Object?>> Function(int slots)? setSlots;

  @override
  State<_WorkerSlotsCard> createState() => _WorkerSlotsCardState();
}

class _WorkerSlotsCardState extends State<_WorkerSlotsCard> {
  Map<String, Object?>? _slots;
  String? _error;
  bool _resetting = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_refresh()),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_resetting) return;
    try {
      final slots = await widget.load();
      if (!mounted) return;
      setState(() {
        _slots = slots;
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not read slots: $error');
    }
  }

  Future<void> _changeSlots(int slots) async {
    final setSlots = widget.setSlots;
    if (setSlots == null) return;
    try {
      final result = await setSlots(slots);
      if (!mounted) return;
      setState(() {
        _slots = result;
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not change parallel slots: $error');
    }
  }

  Future<void> _confirmReset() async {
    final reset = widget.reset;
    if (reset == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset parallel slots?'),
        content: const Text(
          'Running and waiting requests on this Workspace are stopped and all '
          'slots are freed. Your Space folders and files are not touched. '
          'Use this when slots stay busy after a disconnect or a failed '
          'request.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Reset slots'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _resetting = true);
    try {
      final result = await reset();
      if (!mounted) return;
      final stopped = result['stopped'];
      setState(() {
        _slots = result;
        _error = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(stopped is int && stopped > 0
            ? 'Slots reset. $stopped request(s) stopped.'
            : 'Slots reset.'),
      ));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not reset slots: $error');
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final slots = _slots;
    final workers = slots == null
        ? const <Map>[]
        : ((slots['workers'] as List?) ?? const []).whereType<Map>().toList();
    final active = (slots?['active'] as int?) ?? 0;
    final queued = (slots?['queued'] as int?) ?? 0;
    final limit = slots?['limit'] as int?;
    final trackedIds = slots == null
        ? 0
        : ((slots['activeAssignmentIds'] as List?) ?? const []).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Parallel executions',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ),
                if (widget.reset != null)
                  OutlinedButton.icon(
                    onPressed: _resetting ? null : _confirmReset,
                    icon: _resetting
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.restart_alt, size: 18),
                    label: const Text('Reset slots'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (widget.setSlots != null && limit != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'How many requests can run at the same time on this '
                        'computer, whichever Worker runs them.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                    const SizedBox(width: 12),
                    DropdownButton<int>(
                      key: const ValueKey('parallel-slots-select'),
                      value: limit.clamp(minParallelSlots, maxParallelSlots),
                      items: [
                        for (var n = minParallelSlots;
                            n <= maxParallelSlots;
                            n++)
                          DropdownMenuItem(value: n, child: Text('$n')),
                      ],
                      onChanged: _resetting
                          ? null
                          : (value) {
                              if (value != null && value != limit) {
                                unawaited(_changeSlots(value));
                              }
                            },
                    ),
                  ],
                ),
              ),
            Text(
              slots == null
                  ? 'Reading slots…'
                  : '$active${limit == null ? '' : ' of $limit'} slots in use'
                      ' · $queued waiting · $trackedIds tracked request(s)',

              style: theme.textTheme.bodyMedium,
            ),
            for (final worker in workers)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${worker['workerTypeId'] ?? worker['workerId']}: '
                  '${worker['active']} running, ${worker['queued']} waiting',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            if (_error != null)
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
