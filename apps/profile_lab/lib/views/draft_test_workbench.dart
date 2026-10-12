import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../widgets/lab_components.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';
import 'profile_draft_editor.dart';
import 'ai_repair_loop_dialog.dart';
import 'profile_release_diff_view.dart';
import 'test_bench_view.dart';

/// Worker-scoped Draft authoring and test execution.
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
      titleA: 'Local Draft',
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
      case 'repair':
        AiRepairLoopDialog.show(context, c);
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

  String _draftStatus(ProfileLabController c) {
    final local = c.isDirty ? 'Unsaved changes' : 'Saved locally';
    if (c.isV9ProfileRegistry) {
      final cloud = c.candidateIsCloudValidated
          ? 'Candidate validated by Cloud'
          : c.currentProfileDigest == c.currentDraft?.payloadDigest
              ? 'Current published Profile'
              : 'Not validated by Cloud';
      return 'Candidate · $local · $cloud';
    }
    final cloud = switch (c.syncState) {
      DraftSyncState.conflict => 'Cloud conflict',
      DraftSyncState.cloudChanged => 'Cloud draft changed',
      _ => c.cloudDraftExists == true &&
              c.cloudDraftVersion == c.currentDraft!.releaseVersion &&
              c.cloudDigest == c.currentDraft!.payloadDigest &&
              !c.isDirty
          ? 'Synced to Cloud'
          : c.cloudDraftExists == null
              ? 'Cloud status unavailable'
              : 'Not synced to Cloud',
    };
    return 'Draft v${c.currentDraft!.releaseVersion} · $local · $cloud';
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
            if (c.definitionsError != null || c.releasesError != null)
              ErrorState(message: c.definitionsError ?? c.releasesError!),
            FilledButton(
              onPressed: c.canCreateInitialDraft
                  ? () async {
                      try {
                        await c.createInitialDraft();
                      } catch (error) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Could not create draft: $error'),
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
                        ? 'Create Initial Draft'
                        : 'Create blank Profile',
              ),
            ),
          ],
        ),
      );
    }

    final locked = _saving ||
        c.isSavingLocally ||
        c.isSavingToCloud ||
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
                _draftStatus(c),
                key: const ValueKey('draft-status'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Tooltip(
                    message: c.isDirty
                        ? 'Save locally (⌘S)'
                        : c.isV9ProfileRegistry
                            ? 'Validate candidate with Cloud'
                            : 'Sync to Cloud',
                    child: FilledButton.icon(
                      icon: Icon(
                        c.isDirty
                            ? Icons.save_outlined
                            : c.isV9ProfileRegistry
                                ? Icons.verified_outlined
                                : Icons.cloud_upload_outlined,
                        size: 16,
                      ),
                      label: Text(
                        locked
                            ? 'Working…'
                            : c.isDirty
                                ? 'Save'
                                : c.isV9ProfileRegistry
                                    ? (c.isValidatingCandidate
                                        ? 'Validating…'
                                        : 'Validate candidate')
                                    : 'Sync to Cloud',
                      ),
                      onPressed: locked ||
                              c.jsonValidationError != null ||
                              (!c.isDirty &&
                                  (!c.isV9ProfileRegistry &&
                                      (c.currentSession == null ||
                                          c.syncState ==
                                              DraftSyncState.conflict ||
                                          c.syncState ==
                                              DraftSyncState.cloudChanged)))
                          ? null
                          : () => _perform(
                                c.isDirty
                                    ? c.saveCurrentDraft
                                    : c.isV9ProfileRegistry
                                        ? c.validateCurrentDraft
                                        : c.saveCurrentDraftToCloud,
                              ),
                    ),
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
                    tooltip: 'More draft actions',
                    onSelected: _advanced,
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'format',
                        enabled: !locked,
                        child: const Text('Format JSON'),
                      ),
                      const PopupMenuItem(
                        value: 'compare',
                        child: Text('Compare'),
                      ),
                      PopupMenuItem(
                        value: 'revert',
                        enabled: !locked && c.isDirty,
                        child: const Text('Revert'),
                      ),
                      PopupMenuItem(
                        value: 'repair',
                        enabled: !locked && !c.isDirty,
                        child: const Text('Experimental Repair'),
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
