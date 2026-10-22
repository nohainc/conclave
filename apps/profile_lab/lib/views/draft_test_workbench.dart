import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/profile_lab_security.dart';
import '../widgets/lab_components.dart';

import '../controllers/profile_lab_controller.dart';
import '../theme/profile_lab_theme.dart';
import 'profile_draft_editor.dart';
import 'profile_release_diff_view.dart';
import 'profile_publish_confirmation_dialog.dart';
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
  int _selectedTabIndex = 0; // 0: JSON, 1: Tests
  bool _saving = false;

  Future<void> _perform(Future<void> Function() action) async {
    setState(() => _saving = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        final errorMessage = 'Could not complete action: $error';
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            backgroundColor: ProfileLabTheme.failColor,
            behavior: SnackBarBehavior.floating,
            content: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: SelectableText(
                    errorMessage,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                IconButton(
                  key: const Key('copy-error-message-button'),
                  tooltip: 'Copy error message',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy, size: 18, color: Colors.white),
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(
                        text: ProfileLabSecurity.redactSecrets(errorMessage),
                      ),
                    );
                    if (!mounted) return;
                    final m = ScaffoldMessenger.of(context);
                    m.hideCurrentSnackBar();
                    m.showSnackBar(
                      const SnackBar(
                        content: Text('Error message copied'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
              ],
            ),
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
      case 'reload':
        _reloadProfileFile();
      case 'format':
        c.formatCurrentJson();
      case 'compare':
        _compare();
    }
  }

  Future<void> _reloadProfileFile() async {
    final c = widget.controller;
    if (c.currentDraft != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Reload Profile from file?'),
          content: Text(
            'Replace the local candidate with ${c.profileFilePath}? '
            'Unsaved edits and local candidate changes will be lost. '
            'The published Cloud Profile will not change.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Reload'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await _perform(() => c.loadProfileFromFolder(force: true));
  }

  Future<void> _runTests() async {
    setState(() => _selectedTabIndex = 1);
    await _perform(widget.controller.runTestLadder);
  }

  Future<void> _publish() async {
    final c = widget.controller;
    final confirmed = await ProfilePublishConfirmationDialog.show(context, c);
    if (confirmed == true && mounted) {
      await _perform(c.publishCurrentDraft);
    }
  }

  Widget _contentArea(ProfileLabController c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Sub-tabs: JSON and Tests
        Container(
          color: ProfileLabTheme.darkSurface,
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _subTabButton(
                title: 'JSON',
                icon: Icons.code,
                index: 0,
              ),
              const SizedBox(width: 8),
              _subTabButton(
                title: 'Tests',
                icon: Icons.science_outlined,
                index: 1,
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: ProfileLabTheme.borderColor),
        Expanded(
          child: IndexedStack(
            index: _selectedTabIndex,
            children: [
              ProfileDraftEditor(controller: c),
              TestBenchView(controller: c),
            ],
          ),
        ),
      ],
    );
  }

  Widget _subTabButton({
    required String title,
    required IconData icon,
    required int index,
  }) {
    final isSelected = _selectedTabIndex == index;
    return InkWell(
      key: Key('sub-tab-${title.toLowerCase()}'),
      onTap: () => setState(() => _selectedTabIndex = index),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? ProfileLabTheme.primaryAccent.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: isSelected
                ? ProfileLabTheme.primaryAccent
                : ProfileLabTheme.borderColor,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected ? Colors.white : ProfileLabTheme.secondaryText,
            ),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color:
                    isSelected ? Colors.white : ProfileLabTheme.secondaryText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    if (c.currentDraft == null) {
      final name = c.selectedWorkerState.displayName;
      return EmptyState(
        title: 'No Profile file is loaded for $name',
        description:
            'Profile Lab loads ${c.selectedCloudWorker?['workerTypeId']}.json '
            'from ${c.profileFilePath ?? 'the repository'}.',
        action: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (c.definitionsError != null)
              ErrorState(message: c.definitionsError!),
            if (c.profileFileError != null)
              ErrorState(message: c.profileFileError!),
            FilledButton.icon(
              onPressed: _reloadProfileFile,
              icon: const Icon(Icons.refresh),
              label: const Text('Reload from folder'),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final sidebarWidth = constraints.maxWidth < 650 ? 170.0 : 200.0;
        final sidebar = Container(
          width: sidebarWidth,
          color: ProfileLabTheme.darkSurface,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Revision ${c.currentProfileRevision}',
                  key: const ValueKey('draft-status'),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(height: 1, color: ProfileLabTheme.borderColor),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.save_outlined, size: 16),
                  label: const Text('Save'),
                  onPressed:
                      locked || !c.isDirty || c.jsonValidationError != null
                          ? null
                          : () => _perform(c.saveCurrentDraft),
                ),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  icon: const Icon(Icons.verified_outlined, size: 16),
                  label: const Text('Validate'),
                  onPressed:
                      locked || c.isDirty || c.jsonValidationError != null
                          ? null
                          : () => _perform(c.validateCurrentDraft),
                ),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  icon: const Icon(Icons.science_outlined, size: 16),
                  label: const Text('Run tests'),
                  onPressed:
                      locked || c.isDirty || c.jsonValidationError != null
                          ? null
                          : _runTests,
                ),
                const SizedBox(height: 6),
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
                const SizedBox(height: 12),
                const Divider(height: 1, color: ProfileLabTheme.borderColor),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const ValueKey('reload-profile-file'),
                  icon: Icon(
                    c.profileFileUpdateAvailable
                        ? Icons.sync_problem
                        : Icons.refresh,
                    size: 16,
                  ),
                  label: Text(
                    c.profileFileUpdateAvailable
                        ? 'Reload (changed)'
                        : 'Reload from file',
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: locked ? null : _reloadProfileFile,
                ),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  icon: const Icon(Icons.format_align_left, size: 16),
                  label: const Text('Format JSON'),
                  onPressed: locked ? null : () => _advanced('format'),
                ),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  icon: const Icon(Icons.compare_arrows, size: 16),
                  label: const Text('Compare'),
                  onPressed: () => _advanced('compare'),
                ),
              ],
            ),
          ),
        );

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            sidebar,
            const VerticalDivider(width: 1, color: ProfileLabTheme.borderColor),
            Expanded(child: _contentArea(c)),
          ],
        );
      },
    );
  }
}
