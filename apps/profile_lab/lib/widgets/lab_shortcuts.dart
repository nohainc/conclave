import '../widgets/lab_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../controllers/profile_lab_controller.dart';

/// Resource-scoped shortcuts; publication and rollout never have keyboard actions.
class LabShortcuts extends StatefulWidget {
  const LabShortcuts(
      {super.key, required this.controller, required this.child});
  final ProfileLabController controller;
  final Widget child;
  @override
  State<LabShortcuts> createState() => _LabShortcutsState();
}

class _LabShortcutsState extends State<LabShortcuts> {
  bool _running = false;
  bool get _available =>
      !_running &&
      ModalRoute.of(context)?.isCurrent != false &&
      widget.controller.labAccess?.profilesAdmin == true;
  Future<void> _perform(Future<void> Function() action) async {
    if (!_available) return;
    setState(() => _running = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: CopyableMessage('Could not complete action: $error')));
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _save() {
    final c = widget.controller;
    if (c.selectedArea != LabArea.workers ||
        c.workerSubView != WorkerSubView.draftAndTest ||
        c.currentDraft == null ||
        !c.isDirty ||
        c.jsonValidationError != null ||
        c.isTesting ||
        c.isPublishing ||
        c.isSavingLocally ||
        c.isSavingToCloud) {
      return;
    }
    _perform(c.saveCurrentDraft);
  }

  void _refresh() {
    final c = widget.controller;
    if (c.isTesting ||
        c.isPublishing ||
        c.isSavingLocally ||
        c.isSavingToCloud) {
      return;
    }
    switch (c.selectedArea) {
      case LabArea.workspaces:
        if (!c.isLoadingWorkspaces) _perform(c.fetchWorkspaceChannels);
      case LabArea.audit:
        if (!c.isLoadingAudit) _perform(() => c.fetchCloudAudit());
      case LabArea.workers:
        if (c.workerSubView == WorkerSubView.releases &&
            c.selectedDefinitionId != null) {
          if (!c.isLoadingReleases) _perform(() => c.fetchCloudReleases());
        } else if (c.workerSubView == WorkerSubView.draftAndTest &&
            c.currentDraft != null) {
          // refreshEvidence checks Cloud state without replacing the editor text.
          if (!c.isLoadingEvidence) _perform(c.refreshEvidence);
        } else if (!c.isLoadingWorkerCatalog) {
          _perform(c.fetchCloudCatalog);
        }
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true): _refresh
      }, child: Focus(autofocus: true, child: widget.child));
}
