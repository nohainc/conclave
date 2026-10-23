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
    final catalog =
        widget.catalogCoordinator?.snapshot ?? const WorkerCatalogSnapshot();
    final canConfigure = !catalog.refreshing &&
        widget.onConfigureWorker != null &&
        catalog.localRegistryLoaded &&
        catalog.localRegistryError == null;
    final workers = _sortedWorkers(catalog);
    final selected = workers
        .where((worker) => _typeOf(worker) == _selectedType(catalog))
        .firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!widget.serviceAvailable)
        const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
                'Start the service to configure or test Workers. Last saved Worker details are shown below.')),
      if (catalog.refreshing)
        const _WorkerProgressBar(semanticsLabel: 'Refreshing Worker catalog'),
      Expanded(child: LayoutBuilder(builder: (context, constraints) {
        final listWidth = (constraints.maxWidth * .26).clamp(128.0, 224.0) + 20;
        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
              width: listWidth,
              child: ListView(
                key: const PageStorageKey('worker-list-scroll'),
                padding: const EdgeInsets.all(8),
                children: [
                  for (final worker in workers)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: _WorkerSelectorTile(
                        key: Key('worker-selector-${_typeOf(worker)}'),
                        worker: worker,
                        selected: identical(worker, selected),
                        status: _listStatus(worker),
                        onTap: () => setState(
                            () => _selectedWorkerType = _typeOf(worker)),
                      ),
                    ),
                ],
              )),
          const VerticalDivider(width: 1),
          Expanded(
              child: SingleChildScrollView(
            key: PageStorageKey('worker-details-${_selectedType(catalog)}'),
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (selected != null)
                    if (selected.descriptor == null)
                      _buildRetiredWorkerCard(selected, theme)
                    else
                      _buildLogicalWorkerCard(selected, canConfigure, theme)
                  else
                    const Text(
                        'No Workers are available in the Cloud catalog.'),
                  if (catalog.catalogError case final error?)
                    CopyableMessageText(error),
                  if (catalog.localRegistryError case final error?)
                    CopyableMessageText(error),
                ]),
          )),
        ]);
      })),
    ]);
  }

  /// Workers in alphabetical order of their display name, so the list and
  /// the default selection do not depend on catalog order.
  static List<WorkerCatalogWorkerState> _sortedWorkers(
          WorkerCatalogSnapshot catalog) =>
      [...catalog.workers]..sort((a, b) {
          final byName = _nameOf(a).toLowerCase().compareTo(
                _nameOf(b).toLowerCase(),
              );
          return byName != 0 ? byName : _typeOf(a).compareTo(_typeOf(b));
        });

  static String _nameOf(WorkerCatalogWorkerState worker) =>
      worker.descriptor?.displayName ?? _typeOf(worker);

  static String _typeOf(WorkerCatalogWorkerState worker) =>
      worker.descriptor?.workerTypeId ?? worker.localWorker!.workerTypeId;

  _WorkerListStatus _listStatus(WorkerCatalogWorkerState worker) {
    final type = _typeOf(worker);
    final progress = widget.catalogCoordinator?.snapshot.checks[type];
    if (_updatingWorkerTypes.contains(type) ||
        (widget.serviceAvailable &&
            progress?.outcome == WorkerCheckOutcome.running)) {
      return _WorkerListStatus.checking;
    }
    if (worker.descriptor == null) return _WorkerListStatus.retired;
    if (worker.localWorker == null) return _WorkerListStatus.setupRequired;
    if (worker.localWorker!.activationState ==
        LocalWorkerActivationState.disabled) {
      return _WorkerListStatus.disabled;
    }
    if (!widget.serviceAvailable) return _WorkerListStatus.unknown;
    return worker.availabilityLabel == 'Ready'
        ? _WorkerListStatus.ready
        : _WorkerListStatus.attention;
  }

  String? _selectedType(WorkerCatalogSnapshot catalog) {
    final types = _sortedWorkers(catalog).map(_typeOf);
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
    final catalog =
        widget.catalogCoordinator?.snapshot ?? const WorkerCatalogSnapshot();
    final ready = widget.serviceAvailable && view.availabilityLabel == 'Ready';
    final cliName = worker?.toolName ?? entry.providerToolName;
    final version = worker?.toolVersion ??
        (view.providerToolState == WorkspaceProviderToolState.missing
            ? 'Not installed'
            : 'Not checked');
    final revision = profile?['revision'] ?? profile?['releaseVersion'];
    return Row(
      key: Key('worker-catalog-${entry.workerTypeId}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(
                '$cliName $version · Profile ${revision == null ? view.profileState.label : 'revision $revision'}',
                key: Key('worker-summary-${entry.workerTypeId}'),
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            SelectableText(
                models.isEmpty ? 'No models available' : models.join('\n'),
                key: Key('worker-models-${entry.workerTypeId}'),
                style: theme.textTheme.bodyMedium),
            if (worker?.modelCatalog?.stale == true)
              Text('Model list may be out of date.',
                  style: theme.textTheme.bodySmall),
            const SizedBox(height: 20),
            _buildVerification(view, progress),
            if (_actionErrors[entry.workerTypeId] case final error?) ...[
              const SizedBox(height: 8),
              CopyableMessageText(error,
                  style: TextStyle(color: theme.colorScheme.error)),
            ],
            if (!ready) ...[
              const SizedBox(height: 16),
              _WorkerStatusPanel(
                key: Key('worker-attention-${entry.workerTypeId}'),
                ready: false,
                title: widget.serviceAvailable
                    ? view.availabilityLabel
                    : 'Service unavailable',
                detail: widget.serviceAvailable
                    ? view.availabilityDetail
                    : 'Last saved status: ${view.availabilityLabel}. Start the service to verify current availability.',
                issueCode: issue,
              ),
            ],
          ],
        )),
        const SizedBox(width: 20),
        SizedBox(
            width: 180,
            child: Column(
              key: Key('worker-actions-${entry.workerTypeId}'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12)),
                  key: Key('worker-check-updates-${entry.workerTypeId}'),
                  onPressed: widget.serviceAvailable &&
                          !busy &&
                          !catalog.refreshing &&
                          widget.catalogCoordinator != null
                      ? () => _checkWorkerUpdates(entry)
                      : null,
                  icon: const Icon(Icons.update, size: 18),
                  label: const Text('Check for updates'),
                ),
                if (worker == null)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12)),
                    onPressed:
                        canAct ? () => _configureCatalogWorker(entry) : null,
                    icon: const Icon(Icons.settings_outlined, size: 18),
                    label: const Text('Configure'),
                  )
                else ...[
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12)),
                    onPressed: canAct && widget.onReadinessCheck != null
                        ? () => _testCatalogWorker(entry, worker)
                        : null,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: Text(busy ? 'Testing…' : 'Test'),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12)),
                    onPressed: canAct && widget.onSetWorkerEnabled != null
                        ? () => _runCatalogAction(
                            entry, () => _setActivationState(worker, disabled))
                        : null,
                    child: Text(disabled ? 'Enable' : 'Disable'),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12)),
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
              ]
                  .map((action) => Padding(
                      padding: const EdgeInsets.only(bottom: 8), child: action))
                  .toList(),
            )),
      ],
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
    final steps = serviceProgress?.steps ?? const <WorkerCheckStep>[];
    final passiveAt = worker?.lastPassiveProbeAt;
    final liveAt = worker?.lastLiveTestAt;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _VerificationStepRow(
        key: Key('worker-last-availability-$type'),
        label:
            'Passive tests: ${passiveAt == null ? 'Not run' : _checkTime(passiveAt)}',
        status: passiveAt == null
            ? 'skipped'
            : serviceProgress?.mode == 'passive' && !running
                ? serviceProgress!.outcome.name
                : 'unknown',
      ),
      _VerificationStepRow(
        key: Key('worker-last-live-$type'),
        label: 'Live tests: ${liveAt == null ? 'Not run' : _checkTime(liveAt)}',
        status: liveAt == null
            ? 'skipped'
            : worker?.lastLiveTestPassed == null
                ? 'unknown'
                : worker!.lastLiveTestPassed!
                    ? 'passed'
                    : 'failed',
      ),
      if (serviceProgress != null) ...[
        if (running)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: _WorkerProgressBar(
                semanticsLabel: 'Worker verification in progress'),
          ),
        if (!running && steps.isNotEmpty)
          for (final step in _verificationSteps(steps))
            _VerificationStepRow(
              key: Key('worker-check-step-$type-${step.code}'),
              label: step.label,
              status: step.status,
              detail: step.detail,
            ),
        if (serviceProgress.issueCode case final code?)
          CopyableMessageText(
              '${workerIssueLabel(code)}. ${workerIssueRecovery(code)}'),
      ] else if (localPending) ...[
        const _WorkerProgressBar(semanticsLabel: 'Waiting for Worker service'),
        const SizedBox(height: 8),
        Text(_actionStages[type] ?? 'Waiting for service verification…'),
      ] else if (!widget.serviceAvailable)
        const Text(
            'Service unavailable. Showing last saved results; start the service to check again.'),
      if (worker?.lastLiveTestPassed == false &&
          worker?.lastLiveTestDetails != null)
        CopyableMessageText(worker!.lastLiveTestDetails!,
            tooltip: 'Copy test details'),
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
      WorkspaceProviderToolState.unknown => 'Not checked',
      WorkspaceProviderToolState.missing => 'Not installed',
      WorkspaceProviderToolState.available => worker.toolVersion ?? 'Available',
    };
    return Padding(
      key: Key('retired-worker-${worker.workerTypeId}'),
      padding: const EdgeInsets.only(bottom: 12),
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

  Future<void> _checkWorkerUpdates(WorkerDescriptor entry) =>
      _runCatalogAction(entry, () async {
        final coordinator = widget.catalogCoordinator!;
        final before = _profileRevision(coordinator, entry.workerTypeId);
        _actionStages[entry.workerTypeId] = 'Checking for updates…';
        if (mounted) setState(() {});
        await coordinator.refreshWorker(entry.workerTypeId);
        if (!mounted) return;
        final current = coordinator.entryForWorker(entry.workerTypeId);
        final after = _profileRevision(coordinator, entry.workerTypeId);
        final name = current?.displayName ?? entry.displayName;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(current == null
              ? '$name is no longer available in Cloud.'
              : after != null && after != before
                  ? '$name updated to Profile revision $after.'
                  : '$name is up to date.'),
        ));
      });

  static String? _profileRevision(
      WorkspaceWorkerCatalogClient coordinator, String workerTypeId) {
    final details = coordinator.snapshot.workers
        .where((worker) => worker.descriptor?.workerTypeId == workerTypeId)
        .firstOrNull
        ?.profileAvailability
        .details;
    return (details?['revision'] ?? details?['releaseVersion'])?.toString();
  }

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
          'Could not complete the action for ${entry.displayName}. Try again or review the Worker status.\n$error',
        );
      }
    } finally {
      _updatingWorkerTypes.remove(entry.workerTypeId);
      _actionStages.remove(entry.workerTypeId);
      if (mounted) setState(() {});
    }
  }
}

enum _WorkerListStatus {
  ready('Ready'),
  checking('Testing'),
  attention('Needs attention'),
  setupRequired('Setup required'),
  disabled('Disabled'),
  retired('Retired'),
  unknown('Status unavailable');

  const _WorkerListStatus(this.label);

  final String label;
}

/// A Worker entry in the Workers list: provider mark, name, and a trailing
/// readiness indicator.
class _WorkerSelectorTile extends StatelessWidget {
  const _WorkerSelectorTile({
    required this.worker,
    required this.selected,
    required this.status,
    required this.onTap,
    super.key,
  });

  final WorkerCatalogWorkerState worker;
  final bool selected;
  final _WorkerListStatus status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final descriptor = worker.descriptor;
    final type = descriptor?.workerTypeId ?? worker.localWorker!.workerTypeId;
    final name = descriptor?.displayName ?? type;
    final cliName = worker.localWorker?.toolName ??
        descriptor?.providerToolName ??
        'Provider CLI';
    final foreground = selected ? colors.onPrimaryContainer : colors.onSurface;
    return Semantics(
      selected: selected,
      button: true,
      label: '$name, $cliName, ${status.label}',
      excludeSemantics: true,
      child: Material(
        color: selected ? colors.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: colors.onSurface.withValues(alpha: .06),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(children: [
              WorkerBrandIcon(
                workerTypeId: type,
                name: name,
                profileDefinitionId: descriptor?.profileDefinitionId,
                providerToolName: descriptor?.providerToolName ??
                    worker.localWorker?.toolName,
                // Matches the height of the two text lines.
                size: 36,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    Text(
                      cliName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: selected
                            ? colors.onPrimaryContainer.withValues(alpha: .75)
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              _WorkerStatusIcon(status: status, type: type),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Keep the moving indicator distinct from its track in both color schemes.
class _WorkerProgressBar extends StatelessWidget {
  const _WorkerProgressBar({required this.semanticsLabel});
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LinearProgressIndicator(
      color: dark ? const Color(0xFFC5ADFF) : ConclaveBrand.accent,
      backgroundColor: dark ? const Color(0xFF303744) : const Color(0xFFE4E7EC),
      minHeight: 6,
      borderRadius: BorderRadius.circular(3),
      semanticsLabel: semanticsLabel,
    );
  }
}

class _WorkerStatusIcon extends StatelessWidget {
  const _WorkerStatusIcon({required this.status, required this.type});

  final _WorkerListStatus status;
  final String type;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final key = Key('worker-status-$type-${status.name}');
    if (status == _WorkerListStatus.checking) {
      return Tooltip(
        message: status.label,
        child: SizedBox(
          key: key,
          width: 16,
          height: 16,
          child: const CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final (icon, color) = switch (status) {
      _WorkerListStatus.ready => (Icons.check_circle, ConclaveBrand.success),
      _WorkerListStatus.attention => (Icons.error, ConclaveBrand.warning),
      _WorkerListStatus.setupRequired => (
          Icons.add_circle_outline,
          colors.onSurfaceVariant
        ),
      _WorkerListStatus.disabled => (
          Icons.pause_circle_outline,
          colors.onSurfaceVariant
        ),
      _WorkerListStatus.retired => (
          Icons.archive_outlined,
          colors.onSurfaceVariant
        ),
      _WorkerListStatus.unknown => (
          Icons.help_outline,
          colors.onSurfaceVariant
        ),
      _WorkerListStatus.checking => throw StateError('handled above'),
    };
    return Tooltip(
      message: status.label,
      child: Icon(icon, key: key, size: 18, color: color),
    );
  }
}

class _WorkerStatusPanel extends StatelessWidget {
  const _WorkerStatusPanel({
    required this.ready,
    super.key,
    required this.title,
    required this.detail,
    this.issueCode,
  });

  final bool ready;
  final String title;
  final String detail;
  final String? issueCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = ready ? ConclaveBrand.success : ConclaveBrand.warning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall?.copyWith(color: accent)),
        const SizedBox(height: 4),
        CopyableMessageText(detail),
        if (issueCode case final code?)
          Text('Issue code: $code', style: theme.textTheme.bodySmall),
      ],
    );
  }
}

typedef _VerificationStep = ({
  String code,
  String label,
  String status,
  String? detail
});

/// Project Engine evidence for display, hiding version, model discovery and
/// sign-in rows without removing their service evidence or execution. Discovery
/// failures remain visible; successful starts are not synthesized as tests.
List<_VerificationStep> _verificationSteps(List<WorkerCheckStep> steps) => [
      for (final step in steps)
        if (!const {
          'provider_tool_version',
          'model_discovery',
          'authentication'
        }.contains(step.code))
          (
            code: step.code,
            label: switch (step.code) {
              'provider_tool' => 'CLI availability',
              'provider_tool_version' => 'CLI version',
              'model_discovery' => 'Model list',
              'provider_live_execution' => 'Account check',
              'authentication' => 'Sign-in',
              _ => _humanizeCheckCode(step.code),
            },
            status: step.status,
            detail: const {
              'Local provider check passed.',
              'Local configuration check passed.',
            }.contains(step.message)
                ? null
                : step.message,
          ),
    ];

String _humanizeCheckCode(String code) {
  final words = code.split('_').where((word) => word.isNotEmpty).join(' ');
  return words.isEmpty ? code : words[0].toUpperCase() + words.substring(1);
}

class _VerificationStepRow extends StatelessWidget {
  const _VerificationStepRow({
    required this.label,
    required this.status,
    this.detail,
    super.key,
  });

  final String label;

  /// `passed`, `warning`, `failed`, `running`, or `skipped`.
  final String status;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color, text) = switch (status) {
      'passed' => (Icons.check_circle_outline, ConclaveBrand.success, 'Passed'),
      'warning' => (
          Icons.warning_amber_outlined,
          ConclaveBrand.warning,
          'Warning'
        ),
      'failed' => (Icons.error_outline, theme.colorScheme.error, 'Failed'),
      'running' => (Icons.hourglass_top, null, 'Running'),
      'unknown' => (Icons.help_outline, null, 'Result unavailable'),
      _ => (Icons.radio_button_unchecked, null, 'Not run'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Tooltip(
            message: '$label: $text',
            child: Icon(icon, size: 18, color: color, semanticLabel: text)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label),
              if (detail case final detail? when detail.isNotEmpty)
                Text(detail,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ]),
    );
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
    this.load,
    this.serviceAvailable = true,
    this.reset,
    this.setSlots,
    super.key,
  });

  final Future<Map<String, Object?>> Function()? load;
  final bool serviceAvailable;
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
  void didUpdateWidget(covariant WorkerSlotsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serviceAvailable && !oldWidget.serviceAvailable) {
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final load = widget.load;
    if (_resetting || !widget.serviceAvailable || load == null) return;
    try {
      final slots = await load();
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
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          border:
              Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Parallel executions',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w400)),
                ),
                if (limit != null)
                  if (widget.setSlots != null)
                    SizedBox(
                      width: 76,
                      child: DropdownButtonFormField<int>(
                        key: const ValueKey('parallel-slots-select'),
                        initialValue:
                            limit.clamp(minParallelSlots, maxParallelSlots),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          border: OutlineInputBorder(),
                        ),
                        style: theme.textTheme.bodySmall,
                        iconSize: 18,
                        dropdownColor: theme.colorScheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(12),
                        items: [
                          for (var n = minParallelSlots;
                              n <= maxParallelSlots;
                              n++)
                            DropdownMenuItem(value: n, child: Text('$n'))
                        ],
                        onChanged: _resetting || !widget.serviceAvailable
                            ? null
                            : (value) {
                                if (value != null && value != limit) {
                                  unawaited(_changeSlots(value));
                                }
                              },
                      ),
                    )
                  else
                    Text('$limit', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
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
            Row(children: [
              Expanded(
                  child: Text(
                slots == null
                    ? widget.serviceAvailable
                        ? 'Reading slots…'
                        : 'Start the service to view slot usage.'
                    : limit == null
                        ? 'Slots: $active in use'
                        : 'Slots $active/$limit in use',
                key: const ValueKey('parallel-slots-usage'),
                style: theme.textTheme.bodyMedium,
              )),
              if (widget.reset != null)
                TextButton(
                  onPressed: _resetting || !widget.serviceAvailable
                      ? null
                      : _confirmReset,
                  child: Text(_resetting ? 'Resetting…' : 'Reset slots'),
                ),
            ]),
            if (limit != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                key: const ValueKey('parallel-slots-meter'),
                value: limit > 0 ? (active / limit).clamp(0.0, 1.0) : 0,
                semanticsLabel:
                    'Parallel execution capacity: $active of $limit slots in use',
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
              ),
            ],
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
