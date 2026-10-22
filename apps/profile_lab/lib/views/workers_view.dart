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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Horizontal tab controls for the 3 workers after the HUD
        _WorkerTabBar(controller: c),
        const Divider(height: 1, color: ProfileLabTheme.borderColor),
        Expanded(
          child: c.selectedCloudWorker == null
              ? const EmptyState(
                  title: 'Select a Worker',
                  description:
                      'Choose a logical Worker from the Cloud catalog.',
                )
              : Column(
                  children: [
                    if (c.definitionsError != null) Text(c.definitionsError!),
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
                        providerToolName: worker['providerToolName'] as String?,
                        size: 20,
                        transparentBackground: true,
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
