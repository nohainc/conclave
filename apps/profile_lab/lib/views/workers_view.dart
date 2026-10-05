import 'package:conclave_protocol/conclave_protocol.dart';
import 'package:flutter/material.dart';
import '../widgets/lab_components.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';
import 'draft_test_workbench.dart';
import 'releases_view.dart';

class WorkersView extends StatefulWidget {
  const WorkersView({super.key, required this.controller});

  final ProfileLabController controller;

  @override
  State<WorkersView> createState() => _WorkersViewState();
}

class _WorkersViewState extends State<WorkersView> {
  final TextEditingController _searchController = TextEditingController();
  String _filter = '';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _searchController.addListener(() {
      setState(() {
        _filter = _searchController.text.trim().toLowerCase();
      });
    });
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(WorkersView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _showCreateWorkerDialog() {
    final c = widget.controller;
    final workerTypeIdCtrl = TextEditingController();
    final definitionIdCtrl = TextEditingController();
    final displayNameCtrl = TextEditingController();
    final descriptionCtrl = TextEditingController();
    final providerToolCtrl = TextEditingController();
    final sortOrderCtrl = TextEditingController(text: '10');
    final selectedCapabilities = <String>{'text'};
    String releaseStage = 'testing';

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Text('Create Approved Logical Worker'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Registers a new logical Worker identity and initial Profile Definition atomically in Cloud.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: workerTypeIdCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Stable Worker ID (workerTypeId)',
                      hintText: 'e.g. example-worker',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: definitionIdCtrl,
                    decoration: const InputDecoration(
                      labelText:
                          'Initial Profile Definition ID (profileDefinitionId)',
                      hintText: 'e.g. example-profile',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: displayNameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Display Name',
                      hintText: 'e.g. Example Worker',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: descriptionCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Description',
                      hintText: 'Describe the Worker and its purpose',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: providerToolCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Provider Tool Identity (providerToolName)',
                      hintText: 'e.g. provider-tool',
                    ),
                  ),
                  const SizedBox(height: 10),
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Capabilities',
                    ),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: canonicalWorkerCapabilities
                          .map((capability) => FilterChip(
                                label: Text(capability),
                                selected:
                                    selectedCapabilities.contains(capability),
                                onSelected: (selected) {
                                  setDlgState(() {
                                    if (selected) {
                                      selectedCapabilities.add(capability);
                                    } else {
                                      selectedCapabilities.remove(capability);
                                    }
                                  });
                                },
                              ))
                          .toList(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Release Stage:',
                                style: TextStyle(
                                    fontSize: 11, color: Color(0xFF94A3B8))),
                            DropdownButton<String>(
                              value: releaseStage,
                              isExpanded: true,
                              items: const [
                                DropdownMenuItem(
                                    value: 'testing', child: Text('Testing')),
                                DropdownMenuItem(
                                    value: 'beta', child: Text('Beta')),
                                DropdownMenuItem(
                                    value: 'stable', child: Text('Stable')),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setDlgState(() => releaseStage = val);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextField(
                          controller: sortOrderCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Sort Order',
                            hintText: '10',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: ProfileLabTheme.primaryAccent),
              onPressed: () async {
                final wId = workerTypeIdCtrl.text.trim();
                final pId = definitionIdCtrl.text.trim();
                final dName = displayNameCtrl.text.trim();
                final desc = descriptionCtrl.text.trim();
                final pTool = providerToolCtrl.text.trim();
                final caps = canonicalWorkerCapabilities
                    .where(selectedCapabilities.contains)
                    .toList();
                final sortOrder = int.tryParse(sortOrderCtrl.text.trim()) ?? 10;

                if (wId.isEmpty ||
                    pId.isEmpty ||
                    dName.isEmpty ||
                    pTool.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: CopyableMessage(
                            'Please fill out all required fields.')),
                  );
                  return;
                }
                if (caps.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content:
                            CopyableMessage('Select at least one capability.')),
                  );
                  return;
                }

                Navigator.of(ctx).pop();
                try {
                  await c.createWorkerCatalogEntry(
                    workerTypeId: wId,
                    profileDefinitionId: pId,
                    displayName: dName,
                    description: desc,
                    providerToolName: pTool,
                    releaseStage: releaseStage,
                    capabilities: caps,
                    sortOrder: sortOrder,
                  );
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content:
                              Text('Successfully created Worker $wId ($pId)')),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content:
                              CopyableMessage('Failed to create Worker: $e')),
                    );
                  }
                }
              },
              child: const Text('Create Worker',
                  style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final workers = c.cloudWorkers.where((w) {
      if (_filter.isEmpty) return true;
      final typeId = (w['workerTypeId'] ?? '').toString().toLowerCase();
      final name = (w['displayName'] ?? '').toString().toLowerCase();
      final tool = (w['providerToolName'] ?? '').toString().toLowerCase();
      return typeId.contains(_filter) ||
          name.contains(_filter) ||
          tool.contains(_filter);
    }).toList();

    return LayoutBuilder(
        builder: (context, constraints) => Flex(
              direction:
                  constraints.maxWidth < 1000 ? Axis.vertical : Axis.horizontal,
              children: [
                // Left pane: Workers List
                Container(
                  width:
                      constraints.maxWidth < 1000 ? constraints.maxWidth : 280,
                  height: constraints.maxWidth < 1000 ? 240 : null,
                  decoration: const BoxDecoration(
                    color: ProfileLabTheme.darkSurface,
                    border: Border(right: BorderSide(color: Color(0xFF334155))),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Search & refresh header
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                style: const TextStyle(fontSize: 12),
                                decoration: InputDecoration(
                                  hintText: 'Filter workers...',
                                  hintStyle: const TextStyle(
                                      fontSize: 12, color: Color(0xFF64748B)),
                                  prefixIcon: const Icon(Icons.search,
                                      size: 16, color: Color(0xFF94A3B8)),
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                  filled: true,
                                  fillColor: ProfileLabTheme.darkBackground,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(6),
                                    borderSide: const BorderSide(
                                        color: Color(0xFF334155)),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(6),
                                    borderSide: const BorderSide(
                                        color: Color(0xFF334155)),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              icon: const Icon(Icons.add, size: 18),
                              tooltip: 'Create Worker + Definition',
                              onPressed: c.currentSession != null
                                  ? _showCreateWorkerDialog
                                  : null,
                            ),
                            IconButton(
                              icon: c.isLoadingWorkerCatalog
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: ProfileLabTheme.primaryAccent),
                                    )
                                  : const Icon(Icons.refresh, size: 18),
                              tooltip: 'Refresh Cloud Catalog (⌘R)',
                              onPressed: c.isLoadingWorkerCatalog
                                  ? null
                                  : () => c.fetchCloudCatalog(),
                            ),
                          ],
                        ),
                      ),

                      if (c.currentSession == null)
                        Container(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF334155)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Cloud Catalog Unauthenticated',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11,
                                    color: ProfileLabTheme.warnColor),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Sign in with Profile Lab credentials to query the dynamic Cloud catalog.',
                                style: TextStyle(
                                    fontSize: 11, color: Color(0xFF94A3B8)),
                              ),
                              const SizedBox(height: 8),
                              ElevatedButton.icon(
                                icon: const Icon(Icons.login, size: 14),
                                label: const Text('Sign In to Cloud',
                                    style: TextStyle(fontSize: 11)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      ProfileLabTheme.primaryAccent,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                onPressed: () => c.signInWithBrowser(),
                              ),
                            ],
                          ),
                        ),

                      if (c.workerCatalogError != null)
                        Column(children: [
                          Text(c.workerCatalogUnauthorized
                              ? 'Catalog access unauthorized'
                              : 'Catalog refresh failed'),
                          Text(c.workerCatalogError!),
                          TextButton(
                              onPressed: c.isLoadingWorkerCatalog
                                  ? null
                                  : c.fetchCloudCatalog,
                              child: const Text('Retry')),
                        ]),
                      // Workers list
                      Expanded(
                        child: workers.isEmpty
                            ? Center(
                                child: Text(
                                  c.currentSession == null
                                      ? 'Sign in to fetch catalog.'
                                      : c.isLoadingWorkerCatalog
                                          ? 'Fetching catalog...'
                                          : c.workerCatalogError ??
                                              (c.hasLoadedWorkerCatalog
                                                  ? (_filter.isEmpty
                                                      ? 'No logical workers found.'
                                                      : 'No matching workers.')
                                                  : 'Catalog has not been loaded.'),
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFF94A3B8)),
                                ),
                              )
                            : ListView.builder(
                                itemCount: workers.length,
                                itemBuilder: (context, index) {
                                  final worker = workers[index];
                                  final workerTypeId =
                                      worker['workerTypeId'] as String? ?? '';
                                  final isSelected =
                                      c.selectedCloudWorker?['workerTypeId'] ==
                                          workerTypeId;
                                  final stage =
                                      worker['releaseStage'] as String? ??
                                          'testing';
                                  final toolName =
                                      worker['providerToolName'] as String? ??
                                          '';
                                  final workerProfileDefId =
                                      worker['profileDefinitionId'] as String?;

                                  final String profileStatus;
                                  if (isSelected) {
                                    profileStatus = c.selectedWorkerState
                                        .conciseProfileStatus;
                                  } else if (workerProfileDefId == null ||
                                      workerProfileDefId.isEmpty) {
                                    profileStatus = 'No Profile';
                                  } else {
                                    profileStatus = 'Configured';
                                  }

                                  return WorkerSidebarItem(
                                      name: worker['displayName'] as String? ??
                                          workerTypeId,
                                      identity: toolName.isEmpty
                                          ? workerTypeId
                                          : '$workerTypeId · CLI: $toolName',
                                      profileStatus: profileStatus,
                                      catalogStage: stage,
                                      selected: isSelected,
                                      onTap: () => c.selectWorker(worker));
                                },
                              ),
                      ),
                    ],
                  ),
                ),

                // Right pane: Selected Worker Details and Subviews
                Expanded(
                  child: c.selectedCloudWorker == null
                      ? const EmptyState(
                          title: 'Select a Worker',
                          description:
                              'Choose a logical Worker from the Cloud catalog.')
                      : Column(
                          children: [
                            if (c.isLoadingDefinitions)
                              const OperationProgress(label: 'Loading Worker…'),
                            if (c.definitionsError != null)
                              Text(c.definitionsError!),
                            _WorkerSubViewHeader(controller: c),
                            Expanded(
                              child: switch (c.workerSubView) {
                                WorkerSubView.overview => _WorkerDetailsPane(
                                    controller: c,
                                    workerState: c.selectedWorkerState,
                                  ),
                                WorkerSubView.draftAndTest =>
                                  DraftTestWorkbench(controller: c),
                                WorkerSubView.releases =>
                                  ReleasesView(controller: c),
                              },
                            ),
                          ],
                        ),
                ),
              ],
            ));
  }
}

class _WorkerSubViewHeader extends StatelessWidget {
  const _WorkerSubViewHeader({required this.controller});

  final ProfileLabController controller;

  @override
  Widget build(BuildContext context) {
    final worker = controller.selectedCloudWorker;
    final workerTypeId = worker?['workerTypeId'] as String? ?? '';
    final displayName = worker?['displayName'] as String? ?? workerTypeId;
    final toolName = worker?['providerToolName'] as String? ?? '';
    final currentSubView = controller.workerSubView;
    final workerState = controller.selectedWorkerState;
    final defId = workerState.profileDefinitionId ?? 'No Profile Def';
    final providerStatus = workerState.isProviderDetected
        ? 'Detected on PATH'
        : 'Not found on PATH';

    return Padding(
        padding: const EdgeInsets.all(LabSpace.medium),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          LabPageHeader(
              title: displayName,
              description:
                  '($workerTypeId) · Def: $defId · CLI: ${toolName.isEmpty ? "none" : toolName} · $providerStatus',
              actions: [StatusBadge(label: workerState.status.label)]),
          const SizedBox(height: 12),
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<WorkerSubView>(
                  segments: const [
                    ButtonSegment(
                        value: WorkerSubView.overview,
                        label: Text('Overview',
                            key: ValueKey('subview-overview'))),
                    ButtonSegment(
                        value: WorkerSubView.draftAndTest,
                        label: Text('Draft & Test',
                            key: ValueKey('subview-draftAndTest'))),
                    ButtonSegment(
                        value: WorkerSubView.releases,
                        label:
                            Text('Releases', key: ValueKey('subview-releases')))
                  ],
                  selected: {
                    currentSubView
                  },
                  onSelectionChanged: (selected) =>
                      controller.setWorkerSubView(selected.first)))
        ]));
  }
}

class _WorkerDetailsPane extends StatelessWidget {
  const _WorkerDetailsPane({
    required this.controller,
    required this.workerState,
  });

  final ProfileLabController controller;
  final SelectedWorkerState workerState;

  @override
  Widget build(BuildContext context) {
    final nextAction = workerState.nextAction;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(LabSpace.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryActionCard(
              title: nextAction.title,
              description: nextAction.description,
              actionLabel: nextAction.actionLabel,
              status: StatusBadge(label: workerState.status.label),
              onPressed: () async {
                if (controller.canCreateInitialDraft) {
                  try {
                    await controller.createInitialDraft();
                  } catch (error) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: CopyableMessage(
                              'Could not create draft: $error')));
                    }
                  }
                } else if (nextAction.area != LabArea.workers) {
                  controller.setArea(nextAction.area);
                } else {
                  controller.setWorkerSubView(nextAction.subView);
                }
              }),
          const SizedBox(height: 16),
          LifecycleStepper(steps: [
            LabLifecycleStep('Configure',
                isDone: controller.currentDraft != null,
                isActive:
                    workerState.status == WorkerLifecycleStatus.noProfile),
            LabLifecycleStep('Test',
                isDone: workerState.lastTestResult == 'pass',
                isActive:
                    workerState.status == WorkerLifecycleStatus.testRequired),
            LabLifecycleStep('Sync',
                isDone: controller.currentDraft != null &&
                    controller.cloudDigest ==
                        controller.currentDraft!.payloadDigest &&
                    controller.cloudDraftVersion ==
                        controller.currentDraft!.releaseVersion &&
                    !workerState.isDraftDirty),
            LabLifecycleStep('Publish',
                isDone: controller.cloudReleases
                    .any((r) => r['lifecycleState'] != 'draft'),
                isActive:
                    workerState.status == WorkerLifecycleStatus.testsPassed),
            LabLifecycleStep('Rollout',
                isDone: workerState.stableVersion != 'None')
          ]),
          const SizedBox(height: 20),

          // Active Channel Pointers
          const Text(
            'Release channels',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ReleaseChannelCard(
                  channel: 'Testing Channel',
                  version: workerState.testingVersion == 'None'
                      ? null
                      : 'v${workerState.testingVersion}',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ReleaseChannelCard(
                  channel: 'Beta Channel',
                  version: workerState.betaVersion == 'None'
                      ? null
                      : 'v${workerState.betaVersion}',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ReleaseChannelCard(
                  channel: 'Stable Channel',
                  version: workerState.stableVersion == 'None'
                      ? null
                      : 'v${workerState.stableVersion}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Collapsible Technical details Panel
          TechnicalInspector(
            subtitle: Text(
                '${workerState.workerTypeId} · ${workerState.profileDefinitionId ?? "No definition"} · Catalog stage: ${workerState.catalogReleaseStage}'),
            children: [
              _PropertyRow(
                  label: 'Worker Type ID',
                  value: workerState.workerTypeId,
                  isMonospace: true),
              const Divider(color: Color(0xFF334155)),
              _PropertyRow(
                  label: 'Profile Definition ID',
                  value: workerState.profileDefinitionId ?? 'Not configured',
                  isMonospace: true),
              const Divider(color: Color(0xFF334155)),
              _PropertyRow(
                  label: 'Provider CLI Name',
                  value: workerState.providerToolName.isNotEmpty
                      ? workerState.providerToolName
                      : 'Unknown'),
              const Divider(color: Color(0xFF334155)),
              _PropertyRow(
                  label: 'Provider Detection',
                  value: workerState.isProviderDetected
                      ? 'Detected (${workerState.providerDetectedPath})'
                      : 'Not detected on PATH'),
              const Divider(color: Color(0xFF334155)),
              _PropertyRow(
                  label: 'Catalog Release Stage',
                  value: 'Catalog stage: ${workerState.catalogReleaseStage}'),
              const Divider(color: Color(0xFF334155)),
              _PropertyRow(
                  label: 'Worker Lifecycle State',
                  value: workerState.lifecycleState.toUpperCase()),
              const Divider(color: Color(0xFF334155)),
              _PropertyRow(
                  label: 'Visibility State',
                  value: workerState.visibilityState.toUpperCase()),
              const Divider(color: Color(0xFF334155)),
              _PropertyRow(
                  label: 'Engine Family', value: 'cli (generic worker engine)'),
              const Divider(color: Color(0xFF334155)),
              _PropertyRow(label: 'Schema Version', value: 'v1'),
              const Divider(color: Color(0xFF334155)),
              _PropertyRow(
                  label: 'Sort Order', value: workerState.sortOrder.toString()),
              if (workerState.capabilities.isNotEmpty) ...[
                const Divider(color: Color(0xFF334155)),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Capabilities',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF94A3B8))),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 6,
                          runSpacing: 6,
                          children: workerState.capabilities
                              .map(
                                (cap) => Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF334155),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    cap,
                                    style: const TextStyle(
                                        fontFamily: 'Menlo',
                                        fontSize: 10,
                                        color: Color(0xFFE2E8F0)),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 24),

          // Action buttons to jump to other subviews / activity
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              ElevatedButton.icon(
                icon: const Icon(Icons.edit, size: 16),
                label: const Text('Edit / Test in Draft & Test'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ProfileLabTheme.primaryAccent,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                onPressed: () {
                  controller.setWorkerSubView(WorkerSubView.draftAndTest);
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.history, size: 16),
                label: const Text('Inspect Releases'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF475569)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                onPressed: () {
                  controller.setWorkerSubView(WorkerSubView.releases);
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.history_edu, size: 16),
                label: const Text('View Activity Log'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF475569)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                onPressed: () {
                  controller.setArea(LabArea.audit);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PropertyRow extends StatelessWidget {
  const _PropertyRow({
    required this.label,
    required this.value,
    this.isMonospace = false,
  });

  final String label;
  final String value;
  final bool isMonospace;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFamily: isMonospace ? 'Menlo' : null,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
