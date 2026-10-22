import 'package:conclave_design/conclave_design.dart';
import 'package:flutter/material.dart';
import '../widgets/lab_components.dart';
import '../widgets/worker_brand_icon.dart';

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
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final workers = c.cloudWorkers;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Horizontal tab controls for the 3 workers after the HUD
        _WorkerTabBar(controller: c),
        const Divider(height: 1, color: ProfileLabTheme.borderColor),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 760;
              final sidebarWidth = narrow
                  ? constraints.maxWidth
                  : (constraints.maxWidth * .26).clamp(128.0, 224.0) + 20;

              return Flex(
                direction: narrow ? Axis.vertical : Axis.horizontal,
                children: [
                  // Left pane: Workers List
                  Container(
                    width: sidebarWidth,
                    height: narrow ? 220 : null,
                    decoration: const BoxDecoration(
                      color: ProfileLabTheme.darkSurface,
                      border: Border(
                        right: BorderSide(color: ProfileLabTheme.borderColor),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
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
                              border: Border.all(
                                  color: ProfileLabTheme.borderColor),
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
                                    backgroundColor:
                                        ProfileLabTheme.primaryAccent,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
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
                                                    ? 'No logical workers found.'
                                                    : 'Catalog has not been loaded.'),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: ProfileLabTheme.secondaryText,
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  padding: const EdgeInsets.all(8),
                                  itemCount: workers.length,
                                  itemBuilder: (context, index) {
                                    final worker = workers[index];
                                    final workerTypeId =
                                        worker['workerTypeId'] as String? ?? '';
                                    final isSelected = c.selectedCloudWorker?[
                                            'workerTypeId'] ==
                                        workerTypeId;

                                    final status = _determineStatus(c, worker, isSelected);

                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 2),
                                      child: _WorkerSelectorTile(
                                        key: Key('worker-selector-$workerTypeId'),
                                        worker: worker,
                                        selected: isSelected,
                                        status: status,
                                        onTap: () => c.selectWorker(worker),
                                      ),
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
                              if (c.definitionsError != null)
                                Text(c.definitionsError!),
                              Expanded(
                                child: DraftTestWorkbench(
                                  controller: c,
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  static _WorkerListStatus _determineStatus(
    ProfileLabController c,
    Map<String, dynamic> worker,
    bool isSelected,
  ) {
    if (isSelected && c.isTesting) {
      return _WorkerListStatus.checking;
    }
    final lifecycleState =
        (worker['lifecycleState'] as String? ?? '').toLowerCase();
    if (lifecycleState == 'retired') {
      return _WorkerListStatus.retired;
    }
    if (lifecycleState == 'disabled') {
      return _WorkerListStatus.disabled;
    }

    final currentRevision =
        (worker['currentRevision'] as num?)?.toInt() ?? 0;
    if (isSelected) {
      final selectedState = c.selectedWorkerState;
      if (selectedState.lastTestResult == 'fail') {
        return _WorkerListStatus.attention;
      }
      if (selectedState.hasLocalCandidate &&
          selectedState.status == WorkerLifecycleStatus.testsPassed) {
        return _WorkerListStatus.ready;
      }
    }

    if (currentRevision > 0) {
      return _WorkerListStatus.ready;
    }
    return _WorkerListStatus.setupRequired;
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

  final Map<String, dynamic> worker;
  final bool selected;
  final _WorkerListStatus status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final type = worker['workerTypeId'] as String? ?? '';
    final name = worker['displayName'] as String? ?? type;
    final cliName = worker['providerToolName'] as String? ?? 'Provider CLI';
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
                profileDefinitionId:
                    worker['profileDefinitionId'] as String?,
                providerToolName: worker['providerToolName'] as String?,
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

class _WorkerTabBar extends StatelessWidget {
  const _WorkerTabBar({required this.controller});

  final ProfileLabController controller;

  static const List<Map<String, String>> _defaultWorkers = [
    {
      'workerTypeId': 'chatgpt',
      'displayName': 'ChatGPT',
      'profileDefinitionId': 'chatgpt-codex',
      'providerToolName': 'codex',
    },
    {
      'workerTypeId': 'claude',
      'displayName': 'Claude',
      'profileDefinitionId': 'claude-code',
      'providerToolName': 'claude',
    },
    {
      'workerTypeId': 'gemini',
      'displayName': 'Gemini',
      'profileDefinitionId': 'gemini-antigravity',
      'providerToolName': 'agy',
    },
  ];

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final selectedTypeId = c.selectedCloudWorker?['workerTypeId'] as String? ??
        c.selectedWorkerState.workerTypeId;

    // Use loaded cloud workers or default to the canonical 3 workers
    final workersList = <Map<String, dynamic>>[];
    for (final def in _defaultWorkers) {
      final match = c.cloudWorkers.firstWhere(
        (w) => w['workerTypeId'] == def['workerTypeId'],
        orElse: () => def,
      );
      workersList.add(match);
    }
    // Also include any other cloud workers not in the canonical 3
    for (final w in c.cloudWorkers) {
      final typeId = w['workerTypeId'] as String?;
      if (typeId != null &&
          !workersList.any((existing) => existing['workerTypeId'] == typeId)) {
        workersList.add(w);
      }
    }

    return Container(
      color: ProfileLabTheme.darkSurface,
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: workersList.map((worker) {
            final typeId = worker['workerTypeId'] as String? ?? '';
            final name = worker['displayName'] as String? ?? typeId;
            final isSelected = selectedTypeId == typeId;

            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                key: Key('worker-tab-$typeId'),
                onTap: () => c.selectWorker(worker),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? ProfileLabTheme.primaryAccent.withValues(alpha: 0.18)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isSelected
                          ? ProfileLabTheme.primaryAccent
                          : ProfileLabTheme.borderColor,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      WorkerBrandIcon(
                        workerTypeId: typeId,
                        name: name,
                        profileDefinitionId:
                            worker['profileDefinitionId'] as String?,
                        providerToolName:
                            worker['providerToolName'] as String?,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w500,
                          color: isSelected
                              ? Colors.white
                              : ProfileLabTheme.secondaryText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
