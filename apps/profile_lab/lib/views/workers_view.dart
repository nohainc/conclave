import 'package:conclave_design/conclave_design.dart';
import 'package:flutter/material.dart';
import '../widgets/lab_components.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';
import 'draft_test_workbench.dart';

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
            width: constraints.maxWidth < 1000 ? constraints.maxWidth : 280,
            height: constraints.maxWidth < 1000 ? 240 : null,
            decoration: const BoxDecoration(
              color: ProfileLabTheme.darkSurface,
              border: Border(
                right: BorderSide(color: ProfileLabTheme.borderColor),
              ),
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
                              fontSize: 12,
                              color: ProfileLabTheme.secondaryText,
                            ),
                            prefixIcon: const Icon(
                              Icons.search,
                              size: 16,
                              color: ProfileLabTheme.secondaryText,
                            ),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            filled: true,
                            fillColor: ProfileLabTheme.darkBackground,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide: const BorderSide(
                                color: ProfileLabTheme.borderColor,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide: const BorderSide(
                                color: ProfileLabTheme.borderColor,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: c.isLoadingWorkerCatalog
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: ProfileLabTheme.primaryAccent,
                                ),
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
                      horizontal: 12,
                      vertical: 4,
                    ),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: ProfileLabTheme.darkSurface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: ProfileLabTheme.borderColor),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Cloud Catalog Unauthenticated',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                            color: ProfileLabTheme.warnColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Sign in with Profile Lab credentials to query the dynamic Cloud catalog.',
                          style: TextStyle(
                            fontSize: 11,
                            color: ProfileLabTheme.secondaryText,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.login, size: 14),
                          label: const Text(
                            'Sign In to Cloud',
                            style: TextStyle(fontSize: 11),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: ProfileLabTheme.primaryAccent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () => c.signInWithBrowser(),
                        ),
                      ],
                    ),
                  ),

                if (c.workerCatalogError != null)
                  Column(
                    children: [
                      Text(
                        c.workerCatalogUnauthorized
                            ? 'Catalog access unauthorized'
                            : 'Catalog refresh failed',
                      ),
                      Text(c.workerCatalogError!),
                      TextButton(
                        onPressed: c.isLoadingWorkerCatalog
                            ? null
                            : c.fetchCloudCatalog,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
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
                              fontSize: 12,
                              color: ProfileLabTheme.secondaryText,
                            ),
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
                            final toolName =
                                worker['providerToolName'] as String? ?? '';
                            final currentRevision =
                                (worker['currentRevision'] as num?)?.toInt();

                            final String profileStatus = isSelected
                                ? c.selectedWorkerState.conciseProfileStatus
                                : currentRevision == null
                                    ? 'No Profile'
                                    : 'Current r$currentRevision';

                            return WorkerSidebarItem(
                              name: worker['displayName'] as String? ??
                                  workerTypeId,
                              identity: toolName.isEmpty
                                  ? workerTypeId
                                  : '$workerTypeId · CLI: $toolName',
                              profileStatus: profileStatus,
                              selected: isSelected,
                              onTap: () => c.selectWorker(worker),
                            );
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
                        'Choose a logical Worker from the Cloud catalog.',
                  )
                : Column(
                    children: [
                      if (c.isLoadingDefinitions)
                        const OperationProgress(label: 'Loading Worker…'),
                      if (c.definitionsError != null) Text(c.definitionsError!),
                      _WorkerSubViewHeader(controller: c),
                      Expanded(
                        child: switch (c.workerSubView) {
                          WorkerSubView.overview => _WorkerDetailsPane(
                              controller: c,
                              workerState: c.selectedWorkerState,
                            ),
                          WorkerSubView.draftAndTest => DraftTestWorkbench(
                              controller: c,
                            ),
                        },
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabPageHeader(
            title: displayName,
            description:
                '($workerTypeId) · Def: $defId · CLI: ${toolName.isEmpty ? "none" : toolName} · $providerStatus',
            actions: [StatusBadge(label: workerState.status.label)],
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<WorkerSubView>(
              segments: [
                ButtonSegment(
                  value: WorkerSubView.overview,
                  label: Text('Overview', key: ValueKey('subview-overview')),
                ),
                ButtonSegment(
                  value: WorkerSubView.draftAndTest,
                  label: Text(
                    'Draft & Test',
                    key: ValueKey('subview-draftAndTest'),
                  ),
                ),
              ],
              selected: {currentSubView},
              onSelectionChanged: (selected) =>
                  controller.setWorkerSubView(selected.first),
            ),
          ),
        ],
      ),
    );
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: CopyableMessage(
                          'Could not create draft: $error',
                        ),
                      ),
                    );
                  }
                }
              } else {
                controller.setWorkerSubView(nextAction.subView);
              }
            },
          ),
          const SizedBox(height: 16),
          LifecycleStepper(
            steps: [
              LabLifecycleStep(
                'Configure',
                isDone: controller.currentDraft != null,
                isActive: workerState.status == WorkerLifecycleStatus.noProfile,
              ),
              LabLifecycleStep(
                'Test',
                isDone: workerState.lastTestResult == 'pass',
                isActive:
                    workerState.status == WorkerLifecycleStatus.testRequired,
              ),
              LabLifecycleStep(
                'Validate',
                isDone: controller.candidateIsCloudValidated,
                isActive:
                    workerState.status == WorkerLifecycleStatus.testsPassed,
              ),
              LabLifecycleStep(
                'Publish',
                isDone: controller.currentProfileDigest != null &&
                    controller.currentProfileDigest ==
                        controller.currentDraft?.payloadDigest,
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Current signed Profile snapshot
          Text(
            'Current published Profile',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: ProfileLabTheme.secondaryText,
            ),
          ),
          const SizedBox(height: 8),
          _PropertyRow(
            label: 'Current revision',
            value: controller.currentProfileRevision == 0
                ? 'No published Profile'
                : 'r${controller.currentProfileRevision} · ${controller.currentProfileDigest ?? "digest unavailable"}',
            isMonospace: true,
          ),
          const SizedBox(height: 20),

          // Collapsible Technical details Panel
          TechnicalInspector(
            subtitle: Text(
              '\${workerState.workerTypeId} · \${workerState.profileDefinitionId ?? "No definition"} · Current revision: \${controller.currentProfileRevision == 0 ? "none" : controller.currentProfileRevision}',
            ),
            children: [
              _PropertyRow(
                label: 'Worker Type ID',
                value: workerState.workerTypeId,
                isMonospace: true,
              ),
              const Divider(color: ProfileLabTheme.borderColor),
              _PropertyRow(
                label: 'Profile Definition ID',
                value: workerState.profileDefinitionId ?? 'Not configured',
                isMonospace: true,
              ),
              const Divider(color: ProfileLabTheme.borderColor),
              _PropertyRow(
                label: 'Provider CLI Name',
                value: workerState.providerToolName.isNotEmpty
                    ? workerState.providerToolName
                    : 'Unknown',
              ),
              const Divider(color: ProfileLabTheme.borderColor),
              _PropertyRow(
                label: 'Provider Detection',
                value: workerState.isProviderDetected
                    ? 'Detected (${workerState.providerDetectedPath})'
                    : 'Not detected on PATH',
              ),
              const Divider(color: ProfileLabTheme.borderColor),
              _PropertyRow(
                label: 'Worker Lifecycle State',
                value: workerState.lifecycleState.toUpperCase(),
              ),
              const Divider(color: ProfileLabTheme.borderColor),
              _PropertyRow(
                label: 'Visibility State',
                value: workerState.visibilityState.toUpperCase(),
              ),
              const Divider(color: ProfileLabTheme.borderColor),
              _PropertyRow(
                label: 'Engine Family',
                value: 'cli (generic worker engine)',
              ),
              const Divider(color: ProfileLabTheme.borderColor),
              _PropertyRow(label: 'Schema Version', value: 'v1'),
              const Divider(color: ProfileLabTheme.borderColor),
              _PropertyRow(
                label: 'Sort Order',
                value: workerState.sortOrder.toString(),
              ),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                onPressed: () {
                  controller.setWorkerSubView(WorkerSubView.draftAndTest);
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.history_edu, size: 16),
                label: const Text('View Activity Log'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: ProfileLabTheme.borderColor),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
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
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: ProfileLabTheme.secondaryText,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFamily:
                  isMonospace ? ConclaveTypography.fontFamilyMono : null,
              fontFamilyFallback: isMonospace
                  ? ConclaveTypography.fontFamilyMonoFallback
                  : null,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
