import 'dart:convert';
import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';

import 'ai_assistant_dialog.dart';
import 'ai_repair_loop_dialog.dart';
import 'profile_release_diff_view.dart';

/// Schema-aware Tool Profile v1 Draft Editor with live validation,
/// structured summary panels, compare, revert, and duplicate options.
class DraftsView extends StatefulWidget {
  const DraftsView({super.key, required this.controller});

  final ProfileLabController controller;

  @override
  State<DraftsView> createState() => _DraftsViewState();
}

class _DraftsViewState extends State<DraftsView> {
  late TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController =
        TextEditingController(text: widget.controller.currentJsonText);
  }

  @override
  void didUpdateWidget(DraftsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.controller.isDirty &&
        _textController.text != widget.controller.currentJsonText) {
      _textController.text = widget.controller.currentJsonText;
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _showNewDraftDialog() {
    final defIdCtrl = TextEditingController(text: 'new-worker-profile');
    final workerTypeCtrl = TextEditingController(text: 'new-worker');
    final toolNameCtrl = TextEditingController(text: 'newtool');

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create New Tool Profile Draft'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: defIdCtrl,
              decoration:
                  const InputDecoration(labelText: 'Profile Definition ID'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: workerTypeCtrl,
              decoration:
                  const InputDecoration(labelText: 'Logical Worker Type ID'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: toolNameCtrl,
              decoration:
                  const InputDecoration(labelText: 'Provider Tool Name'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await widget.controller.createNewDraft(
                profileDefinitionId: defIdCtrl.text.trim(),
                workerTypeId: workerTypeCtrl.text.trim(),
                providerToolName: toolNameCtrl.text.trim(),
              );
            },
            child: const Text('Create Draft'),
          ),
        ],
      ),
    );
  }

  void _showCompareDialog() {
    final c = widget.controller;
    Map<String, dynamic>? draftPayload;
    try {
      final decoded = jsonDecode(c.currentJsonText);
      if (decoded is Map<String, dynamic>) {
        draftPayload = decoded;
      }
    } catch (_) {}

    final releases = c.cloudReleases;
    final targetPayload = releases.isNotEmpty
        ? (releases.first['profile'] as Map<String, dynamic>?)
        : null;
    final targetVer = releases.isNotEmpty
        ? 'v${releases.first["releaseVersion"]}'
        : 'Published Release';

    ProfileReleaseDiffDialog.show(
      context,
      titleA: 'Draft (${c.selectedDefinitionId})',
      payloadA: draftPayload,
      titleB: targetVer,
      payloadB: targetPayload,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    return Row(
      children: [
        // Left draft selector list
        Container(
          width: 240,
          decoration: const BoxDecoration(
            color: ProfileLabTheme.darkSurface,
            border: Border(right: BorderSide(color: Color(0xFF334155))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Text(
                      'LOCAL DRAFTS',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF94A3B8)),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.add, size: 18),
                      tooltip: 'New Draft',
                      onPressed: _showNewDraftDialog,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: c.draftDefinitionIds.length,
                  itemBuilder: (ctx, idx) {
                    final id = c.draftDefinitionIds[idx];
                    final isSelected = id == c.selectedDefinitionId;
                    return ListTile(
                      dense: true,
                      selected: isSelected,
                      selectedTileColor:
                          ProfileLabTheme.primaryAccent.withValues(alpha: 0.15),
                      title: Text(
                        id,
                        style: TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 12,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.normal,
                          color: isSelected
                              ? Colors.white
                              : const Color(0xFFCBD5E1),
                        ),
                      ),
                      onTap: () => c.selectDraft(id),
                    );
                  },
                ),
              ),
            ],
          ),
        ),

        // Main Editor Surface
        Expanded(
          child: c.currentDraft == null
              ? const Center(
                  child: Text('Select or create a draft to begin authoring.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8))))
              : Column(
                  children: [
                    // Top Action Toolbar
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: const BoxDecoration(
                        color: ProfileLabTheme.darkSurface,
                        border: Border(
                            bottom: BorderSide(color: Color(0xFF334155))),
                      ),
                      child: Row(
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    c.selectedDefinitionId ?? '',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.amber.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'v${c.currentDraft?.releaseVersion ?? 1} (unsigned draft)',
                                      style: const TextStyle(
                                          fontSize: 10,
                                          color: Colors.amber,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  _SyncStateBadge(syncState: c.syncState),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Digest: ${c.currentDraft?.payloadDigest ?? "n/a"}',
                                style: const TextStyle(
                                    fontFamily: 'Menlo',
                                    fontSize: 10,
                                    color: Color(0xFF94A3B8)),
                              ),
                            ],
                          ),
                          const Spacer(),
                          if (c.isDirty)
                            const Padding(
                              padding: EdgeInsets.only(right: 12),
                              child: Text(
                                'Unsaved changes',
                                style: TextStyle(
                                    color: Colors.amber,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          IconButton(
                            icon: const Icon(Icons.format_indent_increase,
                                size: 16),
                            tooltip: 'Format JSON',
                            onPressed: c.formatCurrentJson,
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.auto_awesome,
                                size: 14, color: ProfileLabTheme.primaryAccent),
                            label: const Text('AI Assist...',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: ProfileLabTheme.primaryAccent)),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(
                                  color: ProfileLabTheme.primaryAccent),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                            ),
                            onPressed: () => AiAssistantDialog.show(context, c),
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.build_circle_outlined,
                                size: 14, color: ProfileLabTheme.warnColor),
                            label: const Text('AI Repair Loop...',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: ProfileLabTheme.warnColor)),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(
                                  color: ProfileLabTheme.warnColor),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                            ),
                            onPressed: () =>
                                AiRepairLoopDialog.show(context, c),
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.compare_arrows, size: 14),
                            label: const Text('Compare...',
                                style: TextStyle(fontSize: 11)),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                            ),
                            onPressed: _showCompareDialog,
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.content_copy, size: 14),
                            label: const Text('Duplicate as Next Release',
                                style: TextStyle(fontSize: 11)),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                            ),
                            onPressed: () =>
                                c.duplicateCurrentDraftAsNextRelease(),
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.undo, size: 14),
                            label: const Text('Revert',
                                style: TextStyle(fontSize: 11)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF94A3B8),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                            ),
                            onPressed:
                                c.isDirty ? () => c.revertCurrentDraft() : null,
                          ),
                          const SizedBox(width: 6),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.save, size: 14),
                            label: const Text('Save Draft',
                                style: TextStyle(fontSize: 11)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: ProfileLabTheme.primaryAccent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              minimumSize: Size.zero,
                            ),
                            onPressed:
                                c.jsonValidationError == null && c.isDirty
                                    ? () => c.saveCurrentDraft()
                                    : null,
                          ),
                          if (c.currentSession != null) ...[
                            const SizedBox(width: 6),
                            ElevatedButton.icon(
                              icon: const Icon(Icons.cloud_upload, size: 14),
                              label: const Text('Save to Cloud',
                                  style: TextStyle(fontSize: 11)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.teal,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                minimumSize: Size.zero,
                              ),
                              onPressed: c.jsonValidationError == null
                                  ? () => c.saveCurrentDraftToCloud()
                                  : null,
                            ),
                            const SizedBox(width: 6),
                            ElevatedButton.icon(
                              icon: const Icon(Icons.verified, size: 14),
                              label: const Text('Publish & Cloud Sign',
                                  style: TextStyle(fontSize: 11)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.indigo,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                minimumSize: Size.zero,
                              ),
                              onPressed:
                                  c.jsonValidationError == null && !c.isDirty
                                      ? () async {
                                          try {
                                            await c.publishCurrentDraft();
                                            if (context.mounted) {
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                const SnackBar(
                                                  content: Text(
                                                      'Draft published & Ed25519 signed by Cloud Signing Boundary.'),
                                                ),
                                              );
                                            }
                                          } catch (e) {
                                            if (context.mounted) {
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                SnackBar(
                                                    content: Text(
                                                        'Publication failed: $e')),
                                              );
                                            }
                                          }
                                        }
                                      : null,
                            ),
                          ],
                        ],
                      ),
                    ),

                    // Conflict Banner
                    if (c.syncState == DraftSyncState.conflict)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color:
                              ProfileLabTheme.failColor.withValues(alpha: 0.15),
                          border: const Border(
                              bottom:
                                  BorderSide(color: ProfileLabTheme.failColor)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.warning_amber_rounded,
                                color: ProfileLabTheme.failColor, size: 18),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'CONFLICT DETECTED: Local edits conflict with updated Cloud draft payload.',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: ProfileLabTheme.failColor),
                              ),
                            ),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.compare_arrows, size: 14),
                              label: const Text('Compare Local vs Cloud',
                                  style: TextStyle(fontSize: 11)),
                              onPressed: () {
                                Map<String, dynamic>? draftPayload;
                                try {
                                  final decoded = jsonDecode(c.currentJsonText);
                                  if (decoded is Map<String, dynamic>) {
                                    draftPayload = decoded;
                                  }
                                } catch (_) {}
                                ProfileReleaseDiffDialog.show(
                                  context,
                                  titleA:
                                      'Local Draft (${c.selectedDefinitionId})',
                                  payloadA: draftPayload,
                                  titleB: 'Cloud Draft (Concurrent)',
                                  payloadB: c.cloudDraftPayload,
                                );
                              },
                            ),
                            const SizedBox(width: 6),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: ProfileLabTheme.failColor),
                              onPressed: () => c.resolveConflictKeepLocal(),
                              child: const Text('Overwrite Cloud Draft',
                                  style: TextStyle(fontSize: 11)),
                            ),
                            const SizedBox(width: 6),
                            OutlinedButton(
                              onPressed: () => c.resolveConflictKeepCloud(),
                              child: const Text('Discard Local Edits',
                                  style: TextStyle(fontSize: 11)),
                            ),
                          ],
                        ),
                      ),

                    // Cloud Changed Banner
                    if (c.syncState == DraftSyncState.cloudChanged)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.15),
                          border: const Border(
                              bottom: BorderSide(color: Colors.blue)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.cloud_download,
                                color: Colors.blue, size: 18),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'CLOUD UPDATED: A newer draft version is available on Cloud.',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue),
                              ),
                            ),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blue),
                              onPressed: () => c.resolveConflictKeepCloud(),
                              child: const Text('Load Cloud Version',
                                  style: TextStyle(fontSize: 11)),
                            ),
                          ],
                        ),
                      ),

                    // Continuous Validation Diagnostics Banner
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: c.jsonValidationError == null
                            ? ProfileLabTheme.passColor.withValues(alpha: 0.12)
                            : ProfileLabTheme.failColor.withValues(alpha: 0.15),
                        border: Border(
                          bottom: BorderSide(
                            color: c.jsonValidationError == null
                                ? ProfileLabTheme.passColor
                                : ProfileLabTheme.failColor,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            c.jsonValidationError == null
                                ? Icons.check_circle_outline
                                : Icons.error_outline,
                            color: c.jsonValidationError == null
                                ? ProfileLabTheme.passColor
                                : ProfileLabTheme.failColor,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              c.jsonValidationError == null
                                  ? 'Valid Tool Profile v1 Schema'
                                  : 'Validation Error: ${c.jsonValidationError}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: c.jsonValidationError == null
                                    ? ProfileLabTheme.passColor
                                    : ProfileLabTheme.failColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Split Editor & Structured Summary Panels
                    Expanded(
                      child: Row(
                        children: [
                          // Left: Schema-aware Monospace JSON Editor
                          Expanded(
                            flex: 6,
                            child: Container(
                              color: ProfileLabTheme.darkBackground,
                              padding: const EdgeInsets.all(12),
                              child: TextField(
                                controller: _textController,
                                maxLines: null,
                                expands: true,
                                style: ProfileLabTheme.monoStyle
                                    .copyWith(fontSize: 11),
                                decoration: const InputDecoration(
                                  border: InputBorder.none,
                                  isDense: true,
                                ),
                                onChanged: c.updateJsonText,
                              ),
                            ),
                          ),
                          const VerticalDivider(
                              width: 1, thickness: 1, color: Color(0xFF334155)),
                          // Right: Structured Summary Panel
                          Expanded(
                            flex: 4,
                            child: _StructuredSummaryPanel(controller: c),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Structured Summary Panel rendering live parsed fields from the draft JSON payload.
class _StructuredSummaryPanel extends StatelessWidget {
  const _StructuredSummaryPanel({required this.controller});

  final ProfileLabController controller;

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic>? parsedJson;
    try {
      final decoded = jsonDecode(controller.currentJsonText);
      if (decoded is Map<String, dynamic>) {
        parsedJson = decoded;
      }
    } catch (_) {}

    if (parsedJson == null) {
      return Container(
        color: ProfileLabTheme.darkSurface,
        padding: const EdgeInsets.all(16),
        child: const Center(
          child: Text(
            'Invalid JSON syntax. Fix syntax to render structured summary.',
            style: TextStyle(fontSize: 11, color: ProfileLabTheme.failColor),
          ),
        ),
      );
    }

    final providerTool =
        parsedJson['providerTool'] as Map<String, dynamic>? ?? {};
    final candidates =
        (providerTool['executableCandidates'] as List?)?.cast<String>() ?? [];
    final discovery = providerTool['discovery'] as Map<String, dynamic>? ?? {};
    final env = parsedJson['environment'] as Map<String, dynamic>? ?? {};
    final capabilities =
        (parsedJson['capabilities'] as List?)?.cast<String>() ?? [];
    final sandbox = parsedJson['sandbox'] as Map<String, dynamic>? ?? {};

    return Container(
      color: ProfileLabTheme.darkSurface,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text('STRUCTURED SUMMARY',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF94A3B8))),
          const SizedBox(height: 8),

          // Identity Card
          _SummaryCard(
            title: 'Profile Identity',
            icon: Icons.badge,
            children: [
              _SummaryRow(
                  label: 'Definition ID',
                  value:
                      parsedJson['profileDefinitionId']?.toString() ?? 'n/a'),
              _SummaryRow(
                  label: 'Worker Type ID',
                  value:
                      parsedJson['logicalWorkerTypeId']?.toString() ?? 'n/a'),
              _SummaryRow(
                  label: 'Release Version',
                  value: 'v${parsedJson['releaseVersion']}'),
              _SummaryRow(
                  label: 'Engine Family',
                  value: parsedJson['engineFamily']?.toString() ?? 'n/a'),
            ],
          ),
          const SizedBox(height: 10),

          // Provider Tool Card
          _SummaryCard(
            title: 'Provider Tool Identity',
            icon: Icons.terminal,
            children: [
              _SummaryRow(
                  label: 'Tool Name',
                  value: providerTool['name']?.toString() ?? 'n/a'),
              _SummaryRow(label: 'Executables', value: candidates.join(', ')),
              _SummaryRow(
                  label: 'PATH Search',
                  value: (discovery['allowPathSearch'] ?? false).toString()),
            ],
          ),
          const SizedBox(height: 10),

          // Capabilities Card
          _SummaryCard(
            title: 'Capabilities & Scope',
            icon: Icons.star_outline,
            children: [
              _SummaryRow(
                  label: 'Capabilities',
                  value:
                      capabilities.isEmpty ? 'none' : capabilities.join(', ')),
            ],
          ),
          const SizedBox(height: 10),

          // Environment & Security Card
          _SummaryCard(
            title: 'Environment & Sandbox',
            icon: Icons.security,
            children: [
              _SummaryRow(
                  label: 'Pass-Through Env',
                  value:
                      ((env['passThroughEnv'] as List?)?.join(', ')) ?? 'none'),
              _SummaryRow(
                  label: 'Network Access',
                  value: (sandbox['allowNetwork'] ?? false).toString()),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ProfileLabTheme.darkBackground,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: ProfileLabTheme.primaryAccent),
              const SizedBox(width: 6),
              Text(title,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
            ],
          ),
          const Divider(height: 12, color: Color(0xFF334155)),
          ...children,
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label,
              style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8))),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontFamily: 'Menlo', fontSize: 10, color: Color(0xFFE2E8F0)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncStateBadge extends StatelessWidget {
  const _SyncStateBadge({required this.syncState});

  final DraftSyncState syncState;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (syncState) {
      DraftSyncState.saved => (ProfileLabTheme.passColor, 'Saved'),
      DraftSyncState.modifiedLocally => (Colors.amber, 'Modified locally'),
      DraftSyncState.cloudChanged => (Colors.blue, 'Cloud changed'),
      DraftSyncState.conflict => (ProfileLabTheme.failColor, 'Conflict'),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style:
            TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.bold),
      ),
    );
  }
}
