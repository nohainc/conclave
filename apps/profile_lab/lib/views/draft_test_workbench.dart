import 'dart:convert';
import 'package:flutter/material.dart';
import '../widgets/lab_components.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';
import 'profile_draft_editor.dart';
import 'ai_assistant_dialog.dart';
import 'ai_repair_loop_dialog.dart';
import 'profile_release_diff_view.dart';
import 'test_bench_view.dart';

/// Worker-scoped Draft authoring and test execution.
class DraftTestWorkbench extends StatefulWidget {
  const DraftTestWorkbench({super.key, required this.controller});

  final ProfileLabController controller;

  @override
  State<DraftTestWorkbench> createState() => _DraftTestWorkbenchState();
}

class _DraftTestWorkbenchState extends State<DraftTestWorkbench> {
  bool _showEditor = true;
  bool _showTests = true;
  bool _showInspector = false;
  double _editorFraction = 0.5;
  bool _saving = false;

  Future<void> _perform(Future<void> Function() action) async {
    setState(() => _saving = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: CopyableMessage('Could not complete action: $error')));
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
    final release = c.cloudReleases.isEmpty ? null : c.cloudReleases.first;
    ProfileReleaseDiffDialog.show(context,
        titleA: 'Local Draft',
        payloadA: payload,
        titleB:
            c.cloudDraftPayload != null ? 'Cloud Draft' : 'Published Release',
        payloadB: c.cloudDraftPayload ??
            release?['profile'] as Map<String, dynamic>?);
  }

  void _advanced(String action) {
    final c = widget.controller;
    switch (action) {
      case 'format':
        c.formatCurrentJson();
      case 'compare':
        _compare();
      case 'duplicate':
        _perform(c.duplicateCurrentDraftAsNextRelease);
      case 'revert':
        _perform(c.revertCurrentDraft);
      case 'proposal':
        AiAssistantDialog.show(context, c);
      case 'repair':
        AiRepairLoopDialog.show(context, c);
    }
  }

  String _draftStatus(ProfileLabController c) {
    final local = c.isDirty ? 'Unsaved changes' : 'Saved locally';
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

  Widget _panes(ProfileLabController c) =>
      LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1000;
        final both = _showEditor && _showTests;
        final extent = wide ? constraints.maxWidth : constraints.maxHeight;
        final available = extent - (both ? 12 : 0);
        final editorExtent = both ? available * _editorFraction : extent;
        final testsExtent = both ? available - editorExtent : extent;
        return Stack(children: [
          Positioned(
              left: 0,
              top: 0,
              width: wide ? editorExtent : constraints.maxWidth,
              height: wide ? constraints.maxHeight : editorExtent,
              child: Offstage(
                  offstage: !_showEditor,
                  child: ProfileDraftEditor(
                      controller: c, showInspector: _showInspector))),
          Positioned(
              left: wide && both ? editorExtent + 12 : 0,
              top: !wide && both ? editorExtent + 12 : 0,
              width: wide ? testsExtent : constraints.maxWidth,
              height: wide ? constraints.maxHeight : testsExtent,
              child: Offstage(
                  offstage: !_showTests, child: TestBenchView(controller: c))),
          if (both)
            Positioned(
              left: wide ? editorExtent : 0,
              top: wide ? 0 : editorExtent,
              width: wide ? 12 : constraints.maxWidth,
              height: wide ? constraints.maxHeight : 12,
              child: Semantics(
                  label: 'Resize editor and tests',
                  child: MouseRegion(
                      cursor: wide
                          ? SystemMouseCursors.resizeColumn
                          : SystemMouseCursors.resizeRow,
                      child: GestureDetector(
                          key: const ValueKey('workbench-divider'),
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragUpdate: wide
                              ? (details) => setState(() {
                                    _editorFraction = (_editorFraction +
                                            details.delta.dx / available)
                                        .clamp(0.3, 0.7);
                                  })
                              : null,
                          onVerticalDragUpdate: !wide
                              ? (details) => setState(() {
                                    _editorFraction = (_editorFraction +
                                            details.delta.dy / available)
                                        .clamp(0.3, 0.7);
                                  })
                              : null,
                          child: ColoredBox(
                              color: ProfileLabTheme.darkSurface,
                              child: Center(
                                  child: Icon(
                                      wide
                                          ? Icons.drag_indicator
                                          : Icons.drag_handle,
                                      size: 12,
                                      color: const Color(0xFF94A3B8))))))),
            ),
        ]);
      });

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    if (c.currentDraft == null) {
      final name = c.selectedWorkerState.displayName;
      return EmptyState(
          title: '$name does not have an implementation Profile yet',
          description: c.cloudReleases.isNotEmpty
              ? 'Open Releases to create a draft from an existing Profile.'
              : c.hasStarterTemplate
                  ? 'Start with the Cloud starter template, then test it locally.'
                  : 'Create a blank Profile using this Worker’s configured identity.',
          action: Column(mainAxisSize: MainAxisSize.min, children: [
            if (c.definitionsError != null || c.releasesError != null)
              ErrorState(message: c.definitionsError ?? c.releasesError!),
            if (c.cloudReleases.isNotEmpty)
              FilledButton(
                  onPressed: () => c.setWorkerSubView(WorkerSubView.releases),
                  child: const Text('Open Releases'))
            else
              FilledButton(
                onPressed: c.canCreateInitialDraft
                    ? () async {
                        try {
                          await c.createInitialDraft();
                        } catch (error) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content:
                                    Text('Could not create draft: $error')));
                          }
                        }
                      }
                    : null,
                child: Text(c.isCreatingInitialDraft
                    ? 'Creating…'
                    : c.hasStarterTemplate
                        ? 'Create Initial Draft'
                        : 'Create blank Profile'),
              ),
          ]));
    }

    final locked = _saving ||
        c.isSavingLocally ||
        c.isSavingToCloud ||
        c.isTesting ||
        c.isPublishing;
    return Column(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: ProfileLabTheme.darkSurface,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_draftStatus(c),
              key: const ValueKey('draft-status'),
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Tooltip(
                    message: c.isDirty ? 'Save locally (⌘S)' : 'Sync to Cloud',
                    child: FilledButton.icon(
                        icon: Icon(
                            c.isDirty
                                ? Icons.save_outlined
                                : Icons.cloud_upload_outlined,
                            size: 16),
                        label: Text(locked
                            ? 'Working…'
                            : c.isDirty
                                ? 'Save'
                                : 'Sync to Cloud'),
                        onPressed: locked ||
                                c.jsonValidationError != null ||
                                (!c.isDirty &&
                                    (c.currentSession == null ||
                                        c.syncState ==
                                            DraftSyncState.conflict ||
                                        c.syncState ==
                                            DraftSyncState.cloudChanged))
                            ? null
                            : () => _perform(c.isDirty
                                ? c.saveCurrentDraft
                                : c.saveCurrentDraftToCloud))),
                IconButton(
                    tooltip: _showEditor ? 'Collapse editor' : 'Show editor',
                    icon: const Icon(Icons.code, size: 18),
                    isSelected: _showEditor,
                    onPressed: () => setState(() {
                          _showEditor = !_showEditor;
                          if (!_showEditor) _showTests = true;
                        })),
                IconButton(
                    tooltip: _showTests ? 'Collapse tests' : 'Show tests',
                    icon: const Icon(Icons.science_outlined, size: 18),
                    isSelected: _showTests,
                    onPressed: () => setState(() {
                          _showTests = !_showTests;
                          if (!_showTests) _showEditor = true;
                        })),
                IconButton(
                    tooltip:
                        _showInspector ? 'Hide Inspector' : 'Show Inspector',
                    icon: const Icon(Icons.view_sidebar_outlined, size: 18),
                    isSelected: _showInspector,
                    onPressed: () => setState(() {
                          _showInspector = !_showInspector;
                          if (_showInspector) _showEditor = true;
                        })),
                PopupMenuButton<String>(
                    tooltip: 'More draft actions',
                    onSelected: _advanced,
                    itemBuilder: (_) => [
                          PopupMenuItem(
                              value: 'format',
                              enabled: !locked,
                              child: const Text('Format JSON')),
                          const PopupMenuItem(
                              value: 'compare', child: Text('Compare')),
                          PopupMenuItem(
                              value: 'duplicate',
                              enabled: !locked &&
                                  !c.isDirty &&
                                  c.jsonValidationError == null,
                              child: const Text('Duplicate as Next Release')),
                          PopupMenuItem(
                              value: 'revert',
                              enabled: !locked && c.isDirty,
                              child: const Text('Revert')),
                          const PopupMenuDivider(),
                          PopupMenuItem(
                              value: 'proposal',
                              enabled: !locked,
                              child: const Text('AI Proposal')),
                          PopupMenuItem(
                              value: 'repair',
                              enabled: !locked && !c.isDirty,
                              child: const Text('Experimental Repair')),
                        ]),
              ]),
        ]),
      ),
      Expanded(child: _panes(c)),
    ]);
  }
}
