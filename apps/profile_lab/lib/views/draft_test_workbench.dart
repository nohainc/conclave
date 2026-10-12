import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../widgets/lab_components.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';
import 'profile_draft_editor.dart';
import 'ai_repair_loop_dialog.dart';
import 'profile_release_diff_view.dart';
import 'profile_publish_confirmation_dialog.dart';
import 'profile_history_dialog.dart';
import 'test_bench_view.dart';

/// Worker-scoped candidate authoring and test execution.
class DraftTestWorkbench extends StatefulWidget {
  const DraftTestWorkbench({
    super.key,
    required this.controller,
    this.onFocusChanged,
  });

  final ProfileLabController controller;
  final ValueChanged<bool>? onFocusChanged;

  @override
  State<DraftTestWorkbench> createState() => _DraftTestWorkbenchState();
}

class _DraftTestWorkbenchState extends State<DraftTestWorkbench> {
  bool _showEditor = true;
  bool _showTests = false;
  bool _showInspector = false;
  double _editorFraction = 0.68;
  bool _focusMode = false;
  bool _saving = false;

  Future<void> _perform(Future<void> Function() action) async {
    setState(() => _saving = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: CopyableMessage('Could not complete action: $error'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _compare() {
    final c = widget.controller;
    Map<String, dynamic>? payload;
    try {
      payload = jsonDecode(c.currentJsonText) as Map<String, dynamic>;
    } catch (_) {}
    ProfileReleaseDiffDialog.show(
      context,
      titleA: 'Local Candidate',
      payloadA: payload,
      titleB: 'Current Profile',
      payloadB: c.currentCloudProfileSnapshot?['profile'] is Map
          ? Map<String, dynamic>.from(
              c.currentCloudProfileSnapshot!['profile'] as Map,
            )
          : null,
    );
  }

  void _advanced(String action) {
    final c = widget.controller;
    switch (action) {
      case 'format':
        c.formatCurrentJson();
      case 'compare':
        _compare();
      case 'revert':
        _perform(c.revertCurrentDraft);
      case 'recovery':
        _perform(() async {
          final restored = await c.restoreLatestRecoverySnapshot();
          if (!restored && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('No recovery snapshot is available.')),
            );
          }
        });
      case 'history':
        ProfileHistoryDialog.show(context, c);
      case 'repair':
        AiRepairLoopDialog.show(context, c);
    }
  }

  Future<void> _runTests() async {
    setState(() => _showTests = true);
    await _perform(widget.controller.runTestLadder);
  }

  Future<void> _publish() async {
    final c = widget.controller;
    final confirmed = await ProfilePublishConfirmationDialog.show(context, c);
    if (confirmed == true && mounted) {
      await _perform(c.publishCurrentDraft);
    }
  }

  void _toggleFocusMode() {
    setState(() {
      _focusMode = !_focusMode;
      if (_focusMode) {
        _showEditor = true;
        _showTests = false;
        _showInspector = false;
      }
    });
    widget.onFocusChanged?.call(_focusMode);
  }

  Widget _panes(ProfileLabController c) => LayoutBuilder(
        builder: (context, constraints) {
          final both = _showEditor && _showTests;
          final available = constraints.maxHeight - (both ? 12 : 0);
          final minimumEditor = available < 500 ? available * 0.5 : 220.0;
          final minimumTests = available < 500 ? available * 0.25 : 180.0;
          final maximumEditor = math.max(
            minimumEditor,
            available - minimumTests,
          );
          final editorExtent = both
              ? (available * _editorFraction)
                  .clamp(minimumEditor, maximumEditor)
              : constraints.maxHeight;
          final testsExtent = available - editorExtent;
          return Column(
            children: [
              if (_showEditor)
                SizedBox(
                  height: editorExtent,
                  width: double.infinity,
                  child: ProfileDraftEditor(
                    controller: c,
                    showInspector: _showInspector,
                  ),
                ),
              if (both)
                SizedBox(
                  height: 12,
                  width: double.infinity,
                  child: Semantics(
                    label: 'Resize editor and tests',
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeRow,
                      child: GestureDetector(
                        key: const ValueKey('workbench-divider'),
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (details) => setState(() {
                          _editorFraction =
                              (_editorFraction + details.delta.dy / available)
                                  .clamp(0.35, 0.85);
                        }),
                        child: const ColoredBox(
                          color: ProfileLabTheme.darkSurface,
                          child: Center(
                            child: Icon(Icons.drag_handle,
                                size: 12, color: ProfileLabTheme.secondaryText),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (_showTests)
                SizedBox(
                  height: both ? testsExtent : constraints.maxHeight,
                  width: double.infinity,
                  child: TestBenchView(controller: c),
                ),
              if (!_showEditor && !_showTests)
                const Expanded(child: SizedBox()),
            ],
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    if (c.currentDraft == null) {
      final name = c.selectedWorkerState.displayName;
      return EmptyState(
        title: '$name does not have an implementation Profile yet',
        description: c.hasStarterTemplate
            ? 'Start with the Cloud starter template, then test it locally.'
            : 'Create a blank Profile using this Worker’s configured identity.',
        action: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (c.definitionsError != null)
              ErrorState(message: c.definitionsError!),
            FilledButton(
              onPressed: c.canCreateInitialDraft
                  ? () async {
                      try {
                        await c.createInitialDraft();
                      } catch (error) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content:
                                  Text('Could not create candidate: $error'),
                            ),
                          );
                        }
                      }
                    }
                  : null,
              child: Text(
                c.isCreatingInitialDraft
                    ? 'Creating…'
                    : c.hasStarterTemplate
                        ? 'Create local candidate'
                        : 'Create blank candidate',
              ),
            ),
          ],
        ),
      );
    }

    final locked = _saving ||
        c.isSavingLocally ||
        c.isTesting ||
        c.isValidatingCandidate ||
        c.isPublishing;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: ProfileLabTheme.darkSurface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Worker Profile · revision ${c.currentProfileRevision}',
                key: const ValueKey('draft-status'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  StatusBadge(
                    label: c.isDirty ? 'Unsaved' : 'Saved',
                    status: c.isDirty ? LabStatus.warning : LabStatus.success,
                    icon: c.isDirty
                        ? Icons.edit_outlined
                        : Icons.check_circle_outline,
                  ),
                  StatusBadge(
                    label: c.jsonValidationError == null ? 'Valid' : 'Invalid',
                    status: c.jsonValidationError == null
                        ? LabStatus.success
                        : LabStatus.error,
                    icon: c.jsonValidationError == null
                        ? Icons.data_object
                        : Icons.error_outline,
                  ),
                  StatusBadge(
                    label: c.isTesting
                        ? 'Running'
                        : !c.testResultMatchesDraft || c.lastTestResult == null
                            ? 'Not Run'
                            : c.lastTestResult == 'pass'
                                ? 'Tests Passed'
                                : 'Tests Failed',
                    status: c.isTesting
                        ? LabStatus.neutral
                        : !c.testResultMatchesDraft || c.lastTestResult == null
                            ? LabStatus.neutral
                            : c.lastTestResult == 'pass'
                                ? LabStatus.success
                                : LabStatus.error,
                    icon: c.isTesting
                        ? Icons.hourglass_top
                        : c.lastTestResult == 'pass' && c.testResultMatchesDraft
                            ? Icons.check_circle_outline
                            : c.lastTestResult == 'fail' &&
                                    c.testResultMatchesDraft
                                ? Icons.error_outline
                                : Icons.science_outlined,
                  ),
                  const SizedBox(width: 2),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.save_outlined, size: 16),
                    label: const Text('Save'),
                    onPressed:
                        locked || !c.isDirty || c.jsonValidationError != null
                            ? null
                            : () => _perform(c.saveCurrentDraft),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.verified_outlined, size: 16),
                    label: const Text('Validate'),
                    onPressed:
                        locked || c.isDirty || c.jsonValidationError != null
                            ? null
                            : () => _perform(c.validateCurrentDraft),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.science_outlined, size: 16),
                    label: const Text('Run tests'),
                    onPressed:
                        locked || c.isDirty || c.jsonValidationError != null
                            ? null
                            : _runTests,
                  ),
                  FilledButton.icon(
                    icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                    label: const Text('Publish'),
                    onPressed: locked ||
                            c.isDirty ||
                            c.jsonValidationError != null ||
                            !c.candidateIsCloudValidated ||
                            !c.testResultMatchesDraft ||
                            c.lastTestResult != 'pass' ||
                            !c.activityMappingTestMatchesDraft ||
                            c.lastActivityMappingReplay?.status == 'failed'
                        ? null
                        : _publish,
                  ),
                  IconButton(
                    tooltip: _showEditor ? 'Collapse editor' : 'Show editor',
                    icon: const Icon(Icons.code, size: 18),
                    isSelected: _showEditor,
                    onPressed: () => setState(() {
                      _showEditor = !_showEditor;
                      if (!_showEditor) _showTests = true;
                    }),
                  ),
                  IconButton(
                    tooltip: _showTests ? 'Collapse tests' : 'Show tests',
                    icon: const Icon(Icons.science_outlined, size: 18),
                    isSelected: _showTests,
                    onPressed: () => setState(() {
                      _showTests = !_showTests;
                      if (!_showTests) _showEditor = true;
                    }),
                  ),
                  IconButton(
                    tooltip:
                        _showInspector ? 'Hide Inspector' : 'Show Inspector',
                    icon: const Icon(Icons.view_sidebar_outlined, size: 18),
                    isSelected: _showInspector,
                    onPressed: () => setState(() {
                      _showInspector = !_showInspector;
                      if (_showInspector) _showEditor = true;
                    }),
                  ),
                  IconButton(
                    tooltip:
                        _focusMode ? 'Exit focused editor' : 'Focus editor',
                    icon: Icon(
                      _focusMode ? Icons.fullscreen_exit : Icons.fullscreen,
                      size: 18,
                    ),
                    isSelected: _focusMode,
                    onPressed: _toggleFocusMode,
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More candidate actions',
                    onSelected: _advanced,
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'format',
                        enabled: !locked,
                        child: const Text('Format JSON'),
                      ),
                      const PopupMenuItem(
                        value: 'compare',
                        child: Text('Compare with current Profile'),
                      ),
                      PopupMenuItem(
                        value: 'revert',
                        enabled: !locked && c.isDirty,
                        child: const Text('Restore saved Profile'),
                      ),
                      PopupMenuItem(
                        value: 'recovery',
                        enabled: !locked,
                        child: const Text('Restore recovery snapshot'),
                      ),
                      PopupMenuItem(
                        value: 'history',
                        enabled: true,
                        child: const Text('Profile history'),
                      ),
                      PopupMenuItem(
                        value: 'repair',
                        enabled: !locked && !c.isDirty,
                        child: const Text('AI Repair'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(child: _panes(c)),
      ],
    );
  }
}
