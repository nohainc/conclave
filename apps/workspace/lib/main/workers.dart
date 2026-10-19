part of '../main.dart';

class _WorkersTab extends StatefulWidget {
  const _WorkersTab({
    required this.isSelected,
    this.catalogCoordinator,
    this.serviceAvailable = true,
    this.onReadinessCheck,
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

  @override
  State<_WorkersTab> createState() => _WorkersTabState();
}

class _WorkersTabState extends State<_WorkersTab> {
  final Set<String> _updatingWorkerTypes = {};
  final Map<String, String> _actionErrors = {};
  final Map<String, String> _actionStages = {};
  String? _selectedWorkerType;

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
                'Start the service to configure or test Workers. Last saved Worker details are shown below.'),
            const SizedBox(height: 16),
          ],
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
                  if (catalog.workers.isNotEmpty) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final worker in catalog.workers)
                          ChoiceChip(
                            key: Key(
                                'worker-selector-${worker.descriptor?.workerTypeId ?? worker.localWorker!.workerTypeId}'),
                            label: Text(worker.descriptor?.displayName ??
                                worker.localWorker!.workerTypeId),
                            selected: _selectedType(catalog) ==
                                (worker.descriptor?.workerTypeId ??
                                    worker.localWorker!.workerTypeId),
                            onSelected: (_) => setState(() =>
                                _selectedWorkerType =
                                    worker.descriptor?.workerTypeId ??
                                        worker.localWorker!.workerTypeId),
                          ),
                      ]),
                    ),
                    const SizedBox(height: 16),
                    for (final worker in catalog.workers)
                      if ((worker.descriptor?.workerTypeId ??
                              worker.localWorker!.workerTypeId) ==
                          _selectedType(catalog))
                        if (worker.descriptor == null)
                          _buildRetiredWorkerCard(worker, theme)
                        else
                          _buildLogicalWorkerCard(worker, canConfigure, theme),
                  ],
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

  String? _selectedType(WorkerCatalogSnapshot catalog) {
    final types = catalog.workers.map((worker) =>
        worker.descriptor?.workerTypeId ?? worker.localWorker!.workerTypeId);
    return types.contains(_selectedWorkerType)
        ? _selectedWorkerType
        : types.firstOrNull;
  }

  Widget _buildLogicalWorkerCard(
    WorkerCatalogWorkerState view,
    bool canConfigure,
    ThemeData theme,
  ) {
    final entry = view.descriptor!;
    final worker = view.localWorker;
    final profile = view.profileAvailability.details;
    final progress =
        widget.catalogCoordinator?.snapshot.checks[entry.workerTypeId];
    final busy = _updatingWorkerTypes.contains(entry.workerTypeId) ||
        (widget.serviceAvailable &&
            progress?.outcome == WorkerCheckOutcome.running);
    final canAct = canConfigure && widget.serviceAvailable && !busy;
    final disabled =
        worker?.activationState == LocalWorkerActivationState.disabled;
    final models = profile?['hasModelDiscovery'] == false
        ? (profile?['staticModelNames'] as List?)
                ?.whereType<String>()
                .toList() ??
            const <String>[]
        : worker?.modelCatalog?.models
                .where((model) => model.status != 'unavailable')
                .map((model) => model.name)
                .toList() ??
            const <String>[];
    final issue = view.issueCode;
    return Card(
      key: Key('worker-catalog-${entry.workerTypeId}'),
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(
                  widget.serviceAvailable && view.availabilityLabel == 'Ready'
                      ? Icons.check_circle_outline
                      : Icons.info_outline,
                  color: widget.serviceAvailable &&
                          view.availabilityLabel == 'Ready'
                      ? ConclaveBrand.success
                      : theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(
                      widget.serviceAvailable
                          ? view.availabilityLabel
                          : 'Service unavailable',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600))),
              if (worker != null)
                _CatalogStatusBadge(label: disabled ? 'Disabled' : 'Enabled'),
            ]),
            const SizedBox(height: 8),
            CopyableMessageText(widget.serviceAvailable
                ? view.availabilityDetail
                : 'Last saved status: ${view.availabilityLabel}. Start the service to verify current availability.'),
            if (issue != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Issue code: $issue',
                    style: theme.textTheme.bodySmall),
              ),
            if (_actionErrors[entry.workerTypeId] case final error?) ...[
              const SizedBox(height: 8),
              CopyableMessageText(error,
                  style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (worker == null)
                FilledButton.icon(
                  onPressed:
                      canAct ? () => _configureCatalogWorker(entry) : null,
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: const Text('Configure'),
                )
              else ...[
                FilledButton.icon(
                  onPressed: canAct && widget.onReadinessCheck != null
                      ? () => _testCatalogWorker(entry, worker)
                      : null,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text(busy ? 'Testing…' : 'Test'),
                ),
                OutlinedButton(
                  onPressed: canAct && widget.onSetWorkerEnabled != null
                      ? () => _runCatalogAction(
                          entry, () => _setActivationState(worker, disabled))
                      : null,
                  child: Text(disabled ? 'Enable' : 'Disable'),
                ),
                OutlinedButton(
                  onPressed: canAct && widget.onSetFullLocalAccess != null
                      ? () => _runCatalogAction(
                          entry,
                          () => _setFullLocalAccess(
                              worker, !worker.fullLocalAccessAuthorized))
                      : null,
                  child: Text(worker.fullLocalAccessAuthorized
                      ? 'Disable full access'
                      : 'Enable full access'),
                ),
              ],
            ]),
            const SizedBox(height: 20),
            _buildVerification(view, progress),
            const Divider(height: 32),
            Text('Installation', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
                'Provider tool: ${worker?.toolName ?? entry.providerToolName}'),
            Text(
                'Installed CLI version: ${worker?.toolVersion ?? (view.providerToolState == WorkspaceProviderToolState.missing ? 'Not installed' : 'Not detected')}'),
            if (profile?['revision'] ?? profile?['releaseVersion']
                case final revision?)
              Text('Profile revision: $revision'),
            Text(
                'Profile status: ${view.profileState == WorkspaceWorkerProfileState.ready ? 'Current' : view.profileState.label}'),
            if (worker != null) ...[
              Text(
                  'Execution permissions: ${worker.fullLocalAccessAuthorized ? 'Full local access' : 'Restricted'}'),
              const SizedBox(height: 8),
              Text(
                  'Models: ${models.isEmpty ? 'Unavailable' : models.join(', ')}'),
              if (worker.modelCatalog?.stale == true)
                const Text(
                    'Model catalog is stale. The service will retry discovery.'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildVerification(
      WorkerCatalogWorkerState view, WorkerCheckProgress? progress) {
    final worker = view.localWorker;
    final type = view.descriptor!.workerTypeId;
    final localPending = _updatingWorkerTypes.contains(type);
    final serviceProgress = widget.serviceAvailable &&
            (!localPending || progress?.outcome == WorkerCheckOutcome.running)
        ? progress
        : null;
    final running = serviceProgress?.outcome == WorkerCheckOutcome.running;
    final theme = Theme.of(context);
    final labels = [
      'Resolve current Profile',
      'Run ${serviceProgress?.mode == 'passive' ? 'availability check' : 'live CLI test'}',
      'Record successful verification'
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Verification', style: theme.textTheme.titleSmall),
      const SizedBox(height: 8),
      if (serviceProgress != null) ...[
        Text(
            '${serviceProgress.mode == 'live' ? 'Live test' : 'Availability check'} · ${switch (serviceProgress.outcome) {
              WorkerCheckOutcome.running => 'Running',
              WorkerCheckOutcome.passed => 'Passed',
              WorkerCheckOutcome.failed => 'Failed',
            }}',
            key: Key('worker-check-status-$type')),
        if (running)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(
                semanticsLabel: 'Worker verification in progress'),
          ),
        for (var index = 0; index < labels.length; index++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Icon(
                index < serviceProgress.phase.index ||
                        serviceProgress.outcome == WorkerCheckOutcome.passed
                    ? Icons.check_circle_outline
                    : index == serviceProgress.phase.index
                        ? serviceProgress.outcome == WorkerCheckOutcome.failed
                            ? Icons.error_outline
                            : Icons.hourglass_top
                        : Icons.radio_button_unchecked,
                size: 18,
                color: index < serviceProgress.phase.index ||
                        serviceProgress.outcome == WorkerCheckOutcome.passed
                    ? ConclaveBrand.success
                    : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(
                      '${labels[index]} · ${index < serviceProgress.phase.index || serviceProgress.outcome == WorkerCheckOutcome.passed ? 'Passed' : index == serviceProgress.phase.index ? running ? 'Running' : 'Failed' : 'Not run'}')),
            ]),
          ),
        if (serviceProgress.issueCode case final code?)
          CopyableMessageText(
              '${workerIssueLabel(code)}. ${workerIssueRecovery(code)}'),
      ] else if (localPending) ...[
        const LinearProgressIndicator(
            semanticsLabel: 'Waiting for Worker service'),
        const SizedBox(height: 8),
        Text(_actionStages[type] ?? 'Waiting for service verification…'),
      ] else if (!widget.serviceAvailable)
        const Text(
            'Service unavailable. Showing last saved verification; start the service to check again.')
      else if (worker?.lastLiveTestAt == null)
        const Text(
            'No live test recorded. Test this Worker to verify it can respond.'),
      if (worker?.lastPassiveProbeAt case final checkedAt?)
        Text('Last availability check: ${_checkTime(checkedAt)}',
            style: theme.textTheme.bodySmall),
      if (worker?.lastLiveTestAt case final testedAt?) ...[
        const SizedBox(height: 8),
        Text(
            'Last live test: ${worker!.lastLiveTestPassed == true ? 'Passed' : 'Failed'} · ${_checkTime(testedAt)}'),
        if (worker.lastLiveTestPassed == false &&
            worker.lastLiveTestDetails != null)
          CopyableMessageText(worker.lastLiveTestDetails!,
              tooltip: 'Copy test details'),
      ],
      const SizedBox(height: 6),
      Text(
          'A live test contacts the provider and may use your account quota. Activation is unchanged by testing.',
          style: theme.textTheme.bodySmall),
    ]);
  }

  String _checkTime(String value) {
    final time = DateTime.tryParse(value)?.toLocal();
    if (time == null) return value;
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
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
                _CatalogStatusBadge(label: view.availabilityLabel),
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
    _actionStages[entry.workerTypeId] = 'Refreshing current Worker Profile…';
    if (mounted) setState(() {});
    await coordinator.refresh();
    _actionStages[entry.workerTypeId] = 'Waiting for service verification…';
    if (mounted) setState(() {});
    return coordinator.entryForWorker(entry.workerTypeId);
  }

  Future<void> _runCatalogAction(
      WorkerDescriptor entry, Future<void> Function() action) async {
    if (!_updatingWorkerTypes.add(entry.workerTypeId)) return;
    _actionErrors.remove(entry.workerTypeId);
    setState(() {});
    try {
      await action();
      await widget.catalogCoordinator?.refreshLocalWorkers();
      if (mounted) setState(() {});
    } on Object catch (error) {
      if (mounted) {
        _actionErrors[entry.workerTypeId] = error.toString();
        showCopyableErrorSnackBar(
          context,
          'Could not complete setup for ${entry.displayName}. Try again or review the Worker status.\n$error',
        );
      }
    } finally {
      _updatingWorkerTypes.remove(entry.workerTypeId);
      _actionStages.remove(entry.workerTypeId);
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
      'Enabled' ||
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

/// From this many slots up, the setting warns that the computer may be
/// overloaded and providers may rate-limit.
const _highParallelSlots = 8;

/// Shows the shared parallel execution slots in use and lets the user reset them when
/// work was abandoned (for example during a disconnect) and slots stay busy.
@visibleForTesting
class WorkerSlotsCard extends StatefulWidget {
  const WorkerSlotsCard({
    required this.load,
    this.reset,
    this.setSlots,
    super.key,
  });

  final Future<Map<String, Object?>> Function() load;
  final Future<Map<String, Object?>> Function()? reset;
  final Future<Map<String, Object?>> Function(int slots)? setSlots;

  @override
  State<WorkerSlotsCard> createState() => _WorkerSlotsCardState();
}

class _WorkerSlotsCardState extends State<WorkerSlotsCard> {
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
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: .5),
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
                        'computer, whichever Worker runs them. Changes apply immediately; '
                        'running requests finish when the limit is lowered.',
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
            if (limit != null && limit >= _highParallelSlots)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'A high value can overload this computer and run into '
                  'provider rate limits.',
                  key: const ValueKey('parallel-slots-high-warning'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            Text(
              slots == null
                  ? 'Reading slots…'
                  : limit == null
                      ? 'Slots: $active in use'
                      : 'Slots $active/$limit in use',
              key: const ValueKey('parallel-slots-usage'),
              style: theme.textTheme.bodyMedium,
            ),
            if (queued > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  queued == 1
                      ? 'Waiting for a free slot'
                      : 'Waiting for a free slot · $queued requests',
                  key: const ValueKey('parallel-slots-waiting'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            // Slots are one shared pool, so Workers show no slot counts of
            // their own. A tracked-request count that disagrees with what is
            // running or waiting means slot bookkeeping is stuck.
            if (slots != null && trackedIds != active + queued)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Slot usage looks out of sync. Use Reset slots if work '
                  'does not start.',
                  key: const ValueKey('parallel-slots-out-of-sync'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
