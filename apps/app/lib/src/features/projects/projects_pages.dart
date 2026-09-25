import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../studio/studio_data.dart';
import '../../studio/studio_models.dart';

class ProjectPage extends StatelessWidget {
  const ProjectPage({
    super.key,
    required this.project,
    required this.dataSource,
    required this.onOpenWorkstream,
    this.onEdit,
    required this.onArchive,
    required this.onDelete,
    this.onProjectUpdated,
  });

  final StudioProject project;
  final StudioDataSource dataSource;
  final ValueChanged<String> onOpenWorkstream;
  final VoidCallback? onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final ValueChanged<StudioProject>? onProjectUpdated;

  @override
  Widget build(BuildContext context) => _ProjectWorkspace(
        key: ValueKey(project.id),
        project: project,
        dataSource: dataSource,
        onOpenWorkstream: onOpenWorkstream,
        onEdit: onEdit,
        onArchive: onArchive,
        onDelete: onDelete,
        onProjectUpdated: onProjectUpdated,
      );
}

class _ProjectWorkspace extends StatefulWidget {
  const _ProjectWorkspace({
    super.key,
    required this.project,
    required this.dataSource,
    required this.onOpenWorkstream,
    this.onEdit,
    required this.onArchive,
    required this.onDelete,
    this.onProjectUpdated,
  });

  final StudioProject project;
  final StudioDataSource dataSource;
  final ValueChanged<String> onOpenWorkstream;
  final VoidCallback? onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final ValueChanged<StudioProject>? onProjectUpdated;

  @override
  State<_ProjectWorkspace> createState() => _ProjectWorkspaceState();
}

class _ProjectWorkspaceState extends State<_ProjectWorkspace> {
  int _tabIndex = 0;
  late List<StudioWorkstream> workstreams;
  List<StudioProjectMember> members = const [];
  List<StudioProjectInvitation> invitations = const [];
  List<StudioAuditEntry> audit = const [];
  List<StudioWorkspace> ownedWorkspaces = const [];
  List<Map<String, dynamic>> projectWorkspaces = const [];
  bool loading = true;
  bool executionLoading = true;
  bool _savingField = false;
  String? _editingField;

  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late TextEditingController _repositoryController;
  late TextEditingController _instructionsController;

  bool get canManage =>
      widget.project.role == 'owner' || widget.project.role == 'collaborator';
  bool get isOwner => widget.project.role == 'owner';

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.project.name);
    _descriptionController =
        TextEditingController(text: widget.project.description);
    _repositoryController =
        TextEditingController(text: widget.project.repository);
    _instructionsController =
        TextEditingController(text: widget.project.instructions);
    workstreams = [...widget.project.workstreams];
    _loadCollaboration();
    _loadExecution();
  }

  @override
  void didUpdateWidget(_ProjectWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.project.id != widget.project.id ||
        oldWidget.project.name != widget.project.name ||
        oldWidget.project.description != widget.project.description ||
        oldWidget.project.repository != widget.project.repository ||
        oldWidget.project.instructions != widget.project.instructions) {
      if (_editingField == null) {
        _nameController.text = widget.project.name;
        _descriptionController.text = widget.project.description;
        _repositoryController.text = widget.project.repository;
        _instructionsController.text = widget.project.instructions;
      }
    }
    if (oldWidget.project.id != widget.project.id ||
        oldWidget.project.workstreams != widget.project.workstreams) {
      workstreams = [...widget.project.workstreams];
      loading = true;
      executionLoading = true;
      _loadCollaboration();
      _loadExecution();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _repositoryController.dispose();
    _instructionsController.dispose();
    super.dispose();
  }

  Future<void> _saveField(String field) async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _message('Project name cannot be empty.');
      return;
    }
    setState(() => _savingField = true);
    try {
      final updated = await widget.dataSource.updateProject(
        projectId: widget.project.id,
        name: name,
        description: _descriptionController.text.trim(),
        repository: _repositoryController.text.trim(),
        instructions: _instructionsController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _editingField = null;
        _savingField = false;
      });
      _message('Project updated.');
      widget.onProjectUpdated?.call(updated);
    } catch (error) {
      if (mounted) {
        setState(() => _savingField = false);
        _message(error.toString());
      }
    }
  }

  Future<void> _loadExecution() async {
    try {
      final loaded = await Future.wait([
        widget.dataSource.loadWorkspaces(),
        widget.dataSource.loadProjectWorkspaces(projectId: widget.project.id),
      ]);
      if (!mounted) return;
      setState(() {
        ownedWorkspaces = loaded[0] as List<StudioWorkspace>;
        projectWorkspaces = loaded[1] as List<Map<String, dynamic>>;
        executionLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => executionLoading = false);
    }
  }

  Future<void> _connectWorkspace() async {
    if (ownedWorkspaces.isEmpty) {
      _message(
          'Add a Workspace first. You can connect it to this Project later.');
      return;
    }
    var selectedId = ownedWorkspaces.first.id;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Connect Workspace'),
          content: DropdownButtonFormField<String>(
            initialValue: selectedId,
            decoration: const InputDecoration(labelText: 'Workspace'),
            items: ownedWorkspaces
                .map((workspace) => DropdownMenuItem(
                      value: workspace.id,
                      child: Text(workspace.name),
                    ))
                .toList(),
            onChanged: (value) {
              if (value != null) setDialogState(() => selectedId = value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Connect'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true) return;
    try {
      await widget.dataSource.requestProjectWorkspace(
        projectId: widget.project.id,
        workspaceId: selectedId,
      );
      await _loadExecution();
      _message('Workspace connected to this Project.');
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _revokeWorkspaceGrant(Map<String, dynamic> workspace) async {
    final grantId = (workspace['id'] ?? workspace['grantId'] ?? '').toString();
    final name = (workspace['workspaceName'] ?? workspace['name'] ?? 'Workspace').toString();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Revoke "$name"?'),
        content: const Text(
            'Disconnecting this Workspace will revoke execution capacity for this Project.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      if (grantId.isNotEmpty) {
        await widget.dataSource.revokeWorkspaceProjectGrant(grantId: grantId);
      }
      await _loadExecution();
      _message('Workspace grant revoked.');
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _createWorkstream() async {
    final name = TextEditingController();
    final created = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create Workstream'),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Workstream name'),
          onSubmitted: (_) {
            if (name.text.trim().isNotEmpty) {
              Navigator.pop(dialogContext, true);
            }
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Create Workstream')),
        ],
      ),
    );
    final value = name.text.trim();
    name.dispose();
    if (created != true || value.isEmpty) return;
    try {
      final workstream = await widget.dataSource.createWorkstream(
        projectId: widget.project.id,
        name: value,
      );
      if (!mounted) return;
      setState(() => workstreams = [...workstreams, workstream]);
      widget.onOpenWorkstream(workstream.id);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _editWorkstream(StudioWorkstream workstream) async {
    final nameCtrl = TextEditingController(text: workstream.name);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit Workstream'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Workstream name'),
          onSubmitted: (_) {
            if (nameCtrl.text.trim().isNotEmpty) {
              Navigator.pop(dialogContext, true);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final newName = nameCtrl.text.trim();
    nameCtrl.dispose();
    if (confirmed != true || newName.isEmpty || newName == workstream.name) return;
    try {
      final updated = await widget.dataSource.updateWorkstream(
        workstreamId: workstream.id,
        name: newName,
      );
      if (!mounted) return;
      setState(() {
        workstreams = workstreams
            .map((item) => item.id == updated.id ? updated : item)
            .toList();
      });
      _message('Workstream updated.');
      widget.onProjectUpdated?.call(widget.project);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _deleteWorkstream(StudioWorkstream workstream) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete "${workstream.name}"?'),
        content: const Text(
            'Are you sure you want to delete this Workstream? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.dataSource.deleteWorkstream(workstreamId: workstream.id);
      if (!mounted) return;
      setState(() {
        workstreams =
            workstreams.where((item) => item.id != workstream.id).toList();
      });
      _message('Workstream deleted.');
      widget.onProjectUpdated?.call(widget.project);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _moveWorkstream(int index, int delta) async {
    final targetIndex = index + delta;
    if (targetIndex < 0 || targetIndex >= workstreams.length) return;
    final previousList = List<StudioWorkstream>.from(workstreams);
    final updatedList = List<StudioWorkstream>.from(workstreams);
    final item = updatedList.removeAt(index);
    updatedList.insert(targetIndex, item);
    setState(() {
      workstreams = updatedList;
    });
    try {
      final orderIds = updatedList.map((w) => w.id).toList();
      final updatedProject = await widget.dataSource.updateProject(
        projectId: widget.project.id,
        name: widget.project.name,
        description: widget.project.description,
        repository: widget.project.repository,
        instructions: widget.project.instructions,
        defaultExecutionPolicy: widget.project.defaultExecutionPolicy,
        settings: {
          ...widget.project.settings,
          'workstreamOrder': orderIds,
        },
      );
      if (!mounted) return;
      final mergedProject = StudioProject(
        id: updatedProject.id,
        name: updatedProject.name,
        repository: updatedProject.repository,
        branch: updatedProject.branch,
        activeGoals: updatedProject.activeGoals,
        lastActivity: updatedProject.lastActivity,
        chats: updatedProject.chats.isNotEmpty
            ? updatedProject.chats
            : widget.project.chats,
        workstreams: updatedList,
        description: updatedProject.description,
        instructions: updatedProject.instructions,
        defaultExecutionPolicy: updatedProject.defaultExecutionPolicy,
        archived: updatedProject.archived,
        role: updatedProject.role.isNotEmpty
            ? updatedProject.role
            : widget.project.role,
        settings: updatedProject.settings,
      );
      widget.onProjectUpdated?.call(mergedProject);
    } catch (error) {
      if (mounted) {
        setState(() {
          workstreams = previousList;
        });
        _message(error.toString());
      }
    }
  }

  Future<void> _loadCollaboration() async {
    try {
      final loaded = await Future.wait([
        widget.dataSource.loadProjectMembers(projectId: widget.project.id),
        widget.dataSource.loadProjectInvitations(projectId: widget.project.id),
        widget.dataSource.loadProjectAudit(projectId: widget.project.id),
        widget.dataSource.loadProjectWorkstreams(projectId: widget.project.id),
      ]);
      if (!mounted) return;
      final fetchedWorkstreams = loaded[3] as List<StudioWorkstream>;
      setState(() {
        members = loaded[0] as List<StudioProjectMember>;
        invitations = loaded[1] as List<StudioProjectInvitation>;
        audit = loaded[2] as List<StudioAuditEntry>;
        workstreams = fetchedWorkstreams.isNotEmpty
            ? fetchedWorkstreams
            : widget.project.workstreams;
        loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  void _message(String message) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: const TextStyle(
              color: Color(0xfff4f4f6),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          backgroundColor: const Color(0xff20202a),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          action: SnackBarAction(
            label: 'Copy',
            textColor: const Color(0xffb8a9fe),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: message));
            },
          ),
        ),
      );

  Future<void> _share() async {
    final email = TextEditingController();
    var role = 'collaborator';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Share Project'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: email,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email address'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: role,
              decoration: const InputDecoration(labelText: 'Role'),
              items: const [
                DropdownMenuItem(
                    value: 'collaborator', child: Text('Collaborator')),
                DropdownMenuItem(value: 'viewer', child: Text('Viewer')),
              ],
              onChanged: (value) => setDialogState(() => role = value ?? role),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Send invitation')),
          ],
        ),
      ),
    );
    final address = email.text.trim();
    email.dispose();
    if (accepted != true || address.isEmpty) return;
    try {
      await widget.dataSource.inviteProjectMember(
          projectId: widget.project.id, email: address, role: role);
      _message('Project invitation sent.');
      await _loadCollaboration();
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _changeRole(StudioProjectMember member) async {
    final role = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Role for ${member.displayName}'),
        children: ['collaborator', 'viewer']
            .map((value) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(dialogContext, value),
                  child: Text(value[0].toUpperCase() + value.substring(1)),
                ))
            .toList(),
      ),
    );
    if (role == null || role == member.role) return;
    await widget.dataSource.changeProjectMemberRole(
        projectId: widget.project.id, userId: member.userId, role: role);
    await _loadCollaboration();
  }

  Future<void> _removeMember(StudioProjectMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove "${member.displayName}"?'),
        content: const Text(
            'Are you sure you want to remove this member from the Project?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.dataSource.removeProjectMember(
        projectId: widget.project.id, userId: member.userId);
    _message('${member.displayName} was removed from the Project.');
    await _loadCollaboration();
  }

  Future<void> _revokeInvitation(StudioProjectInvitation invite) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Revoke invitation?'),
        content: Text('Cancel pending invitation for ${invite.email}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.dataSource.expireProjectInvitation(
        projectId: widget.project.id,
        invitationId: invite.id,
      );
      _message('Invitation revoked.');
      await _loadCollaboration();
    } catch (error) {
      _message(error.toString());
    }
  }

  Widget _buildEditableField({
    required String label,
    required String fieldKey,
    required String value,
    required String placeholder,
    required TextEditingController controller,
    int maxLines = 1,
    TextStyle? textStyle,
    IconData? prefixIcon,
    Widget? trailingAction,
    bool showLabel = false,
  }) {
    final isEditing = _editingField == fieldKey;
    if (isEditing) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: true,
                maxLines: maxLines,
                textInputAction:
                    maxLines == 1 ? TextInputAction.done : TextInputAction.newline,
                onSubmitted: (_) {
                  if (!_savingField) _saveField(fieldKey);
                },
                decoration: InputDecoration(
                  labelText: label,
                  isDense: true,
                  border: const OutlineInputBorder(),
                  prefixIcon:
                      prefixIcon != null ? Icon(prefixIcon, size: 18) : null,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Save',
              icon: _savingField
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check, color: Colors.green),
              onPressed: _savingField ? null : () => _saveField(fieldKey),
            ),
            IconButton(
              tooltip: 'Cancel',
              icon: const Icon(Icons.close),
              onPressed: _savingField
                  ? null
                  : () {
                      setState(() {
                        switch (fieldKey) {
                          case 'name':
                            controller.text = widget.project.name;
                            break;
                          case 'description':
                            controller.text = widget.project.description;
                            break;
                          case 'repository':
                            controller.text = widget.project.repository;
                            break;
                          case 'instructions':
                            controller.text = widget.project.instructions;
                            break;
                        }
                        _editingField = null;
                      });
                    },
            ),
          ],
        ),
      );
    }

    final hasValue = value.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (prefixIcon != null) ...[
            Icon(prefixIcon,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showLabel && label.isNotEmpty && fieldKey != 'name')
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      letterSpacing: 0.2,
                    ),
                  ),
                Text(
                  hasValue ? value.trim() : placeholder,
                  style: textStyle ??
                      TextStyle(
                        fontSize: 14,
                        color: hasValue
                            ? null
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        fontStyle:
                            hasValue ? FontStyle.normal : FontStyle.italic,
                      ),
                ),
              ],
            ),
          ),
          if (isOwner)
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 16),
              tooltip: 'Edit $label',
              splashRadius: 16,
              visualDensity: VisualDensity.compact,
              onPressed: () {
                setState(() {
                  _editingField = fieldKey;
                });
              },
            ),
          if (trailingAction != null) ...[
            const SizedBox(width: 4),
            trailingAction,
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Project Data directly without group control card or horizontal lines
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Line 1: Project Name
                _buildEditableField(
                  label: 'Project Name',
                  fieldKey: 'name',
                  value: widget.project.name,
                  placeholder: 'Untitled Project',
                  controller: _nameController,
                  textStyle: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 6),
                // Line 2: Description
                _buildEditableField(
                  label: 'Description',
                  fieldKey: 'description',
                  value: widget.project.description,
                  placeholder: 'No project description provided.',
                  controller: _descriptionController,
                  maxLines: 2,
                ),
                const SizedBox(height: 6),
                // Line 3: Repository
                _buildEditableField(
                  label: 'Repository',
                  fieldKey: 'repository',
                  value: widget.project.repository,
                  placeholder: 'No repository configured.',
                  controller: _repositoryController,
                ),
                const SizedBox(height: 6),
                // Line 4: Instructions
                _buildEditableField(
                  label: 'Project Instructions',
                  fieldKey: 'instructions',
                  value: widget.project.instructions,
                  placeholder: 'No instructions configured.',
                  controller: _instructionsController,
                  maxLines: 3,
                ),
                if (isOwner) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: widget.onArchive,
                        icon: const Icon(Icons.archive_outlined),
                        label: const Text('Archive'),
                      ),
                      TextButton.icon(
                        onPressed: widget.onDelete,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Delete'),
                        style: TextButton.styleFrom(
                            foregroundColor: Colors.red.shade700),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          // 3 Tabs: Workstreams, Workspaces, Members aligned by center
          DefaultTabController(
            initialIndex: _tabIndex,
            length: 3,
            child: Builder(
              builder: (tabContext) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.center,
                      onTap: (index) => setState(() => _tabIndex = index),
                      tabs: const [
                        Tab(text: 'Workstreams'),
                        Tab(text: 'Workspaces'),
                        Tab(text: 'Members'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_tabIndex == 0)
                    _workstreamsTab()
                  else if (_tabIndex == 1)
                    _workspacesTab()
                  else
                    _membersTab(),
                ],
              ),
            ),
          ),
        ],
      );

  Widget _workstreamsTab() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    'Each Workstream is one focused area of team work.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (canManage)
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'Create Workstream',
                    splashRadius: 20,
                    onPressed: _createWorkstream,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (loading)
              const LinearProgressIndicator()
            else if (workstreams.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No workstreams yet.'),
              )
            else
              Column(
                children: workstreams.asMap().entries.map((entry) {
                  final index = entry.key;
                  final workstream = entry.value;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      workstream.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    onTap: () => widget.onOpenWorkstream(workstream.id),
                    trailing: canManage
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.keyboard_arrow_up_rounded),
                                tooltip: 'Move up',
                                iconSize: 20,
                                splashRadius: 16,
                                onPressed: index > 0
                                    ? () => _moveWorkstream(index, -1)
                                    : null,
                              ),
                              IconButton(
                                icon: const Icon(Icons.keyboard_arrow_down_rounded),
                                tooltip: 'Move down',
                                iconSize: 20,
                                splashRadius: 16,
                                onPressed: index < workstreams.length - 1
                                    ? () => _moveWorkstream(index, 1)
                                    : null,
                              ),
                              PopupMenuButton<String>(
                                tooltip: 'Workstream actions',
                                onSelected: (action) {
                                  if (action == 'edit') {
                                    _editWorkstream(workstream);
                                  } else if (action == 'delete') {
                                    _deleteWorkstream(workstream);
                                  }
                                },
                                itemBuilder: (context) => const [
                                  PopupMenuItem(
                                    value: 'edit',
                                    child: Text('Edit / Rename'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete Workstream'),
                                  ),
                                ],
                              ),
                            ],
                          )
                        : null,
                  );
                }).toList(),
              ),
          ],
        ),
      );

  Widget _workspacesTab() => _ProjectPanel(
        title: 'Execution Workspaces',
        subtitle:
            'Workspaces provide execution capacity. They are optional and can be connected or changed after Project creation.',
        child: executionLoading
            ? const LinearProgressIndicator()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (canManage) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: _connectWorkspace,
                        icon: const Icon(Icons.add_link),
                        label: const Text('Connect Workspace'),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (projectWorkspaces.isEmpty)
                    const Text(
                        'No execution Workspace is connected. Collaboration and discussion continue to work normally.')
                  else
                    ...projectWorkspaces.map((workspace) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.computer_outlined),
                          title: Text((workspace['workspaceName'] ??
                                  workspace['name'] ??
                                  workspace['workspaceId'] ??
                                  'Workspace')
                              .toString()),
                          subtitle: Text(
                              '${workspace['status'] ?? 'active'} · ${workspace['scope'] ?? 'project_repository'}'),
                          trailing: isOwner
                              ? OutlinedButton.icon(
                                  onPressed: () =>
                                      _revokeWorkspaceGrant(workspace),
                                  icon: const Icon(Icons.link_off, size: 16),
                                  label: const Text('Revoke'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.red.shade700,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                )
                              : null,
                        )),
                ],
              ),
      );

  Widget _membersTab() => _ProjectPanel(
        title: 'Members',
        subtitle:
            'Project roles control collaboration. They do not grant Workspace access.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isOwner) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _share,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Share Project'),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (loading)
              const LinearProgressIndicator()
            else
              Column(
                children: [
                  if (members.isEmpty)
                    const ListTile(title: Text('No members found')),
                  ...members.map((member) => ListTile(
                        leading: CircleAvatar(
                            child: Text(member.displayName.isEmpty
                                ? '?'
                                : member.displayName[0].toUpperCase())),
                        title: Text(member.displayName),
                        subtitle: Text(member.email),
                        trailing: member.role == 'owner' || !isOwner
                            ? Chip(label: Text(member.role))
                            : PopupMenuButton<String>(
                                tooltip: 'Member actions',
                                onSelected: (action) {
                                  if (action == 'role') {
                                    _changeRole(member);
                                  } else if (action == 'remove') {
                                    _removeMember(member);
                                  }
                                },
                                itemBuilder: (context) => const [
                                  PopupMenuItem(
                                      value: 'role',
                                      child: Text('Change role')),
                                  PopupMenuItem(
                                      value: 'remove',
                                      child: Text('Remove from Project')),
                                ],
                              ),
                      )),
                  if (invitations.isNotEmpty) ...[
                    const Divider(),
                    const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Pending invitations',
                            style: TextStyle(fontWeight: FontWeight.w700))),
                    ...invitations.map((invite) => ListTile(
                          title: Text(invite.email),
                          subtitle: Text(invite.role),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Chip(label: Text('Pending')),
                              if (isOwner) ...[
                                const SizedBox(width: 8),
                                IconButton(
                                  icon: const Icon(Icons.cancel_outlined,
                                      size: 18),
                                  tooltip: 'Revoke invitation',
                                  onPressed: () => _revokeInvitation(invite),
                                ),
                              ],
                            ],
                          ),
                        )),
                  ],
                ],
              ),
          ],
        ),
      );
}

class WorkstreamPage extends StatefulWidget {
  const WorkstreamPage({
    super.key,
    required this.project,
    required this.workstream,
    required this.onBackToProject,
    required this.onArchive,
    required this.onProvisionCheckout,
    this.onRename,
    this.onRunWork,
    this.initialTab = 0,
  });

  final StudioProject project;
  final StudioWorkstream workstream;
  final VoidCallback onBackToProject;
  final VoidCallback onArchive;
  final VoidCallback onProvisionCheckout;
  final Future<void> Function(String name)? onRename;
  final ValueChanged<String>? onRunWork;
  final int initialTab;

  @override
  State<WorkstreamPage> createState() => _WorkstreamPageState();
}

class _WorkstreamPageState extends State<WorkstreamPage> {
  final _requestController = TextEditingController();
  final _discussionController = TextEditingController();
  final _briefPurposeController = TextEditingController();
  final _briefStateController = TextEditingController();
  final _briefConstraintsController = TextEditingController();
  final _briefOutcomeController = TextEditingController();
  String _workflow = 'Full Cycle';
  String _quality = 'Balanced';
  String _account = 'Auto';
  String _accountMode = 'requester';
  String _workstreamBudget = 'No budget';
  String _requestEstimate = 'Auto estimate';
  String _model = 'Auto';
  bool _advanced = false;
  bool _references = false;
  late int _tabIndex = widget.initialTab;
  final List<_WorkTimelineItem> _timeline = [];
  final List<_DiscussionItem> _discussion = [];
  final Set<String> _selectedDiscussionIds = <String>{};
  List<String> _draftReferences = <String>[];
  bool _editingBrief = false;

  @override
  void initState() {
    super.initState();
    _briefPurposeController.text = widget.workstream.brief;
    _briefStateController.text = widget.workstream.status;
    _briefConstraintsController.text =
        'Use the Project policy and the Workstream Primary Workspace.';
    _briefOutcomeController.text =
        'A verified result with an understandable checkpoint and evidence.';
  }

  bool get _canExecute =>
      widget.project.role == 'owner' || widget.project.role == 'collaborator';

  Future<void> _rename() async {
    if (widget.onRename == null) return;
    var name = widget.workstream.name;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename Workstream'),
        content: TextField(
          autofocus: true,
          controller: TextEditingController(text: name),
          onChanged: (value) => name = value,
          decoration: const InputDecoration(labelText: 'Workstream name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (accepted == true && name.trim().isNotEmpty) {
      await widget.onRename!(name.trim());
    }
  }

  @override
  void dispose() {
    _requestController.dispose();
    _discussionController.dispose();
    _briefPurposeController.dispose();
    _briefStateController.dispose();
    _briefConstraintsController.dispose();
    _briefOutcomeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        initialIndex: _tabIndex,
        length: 2,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 10,
            children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.project.name,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12)),
                const SizedBox(height: 5),
                Text(widget.workstream.name,
                    style: const TextStyle(
                        fontSize: 25, fontWeight: FontWeight.w700)),
              ]),
              Wrap(spacing: 8, children: [
                OutlinedButton.icon(
                  onPressed: widget.onBackToProject,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Project'),
                ),
                if (widget.project.role == 'owner' ||
                    widget.project.role == 'collaborator')
                  TextButton.icon(
                    onPressed: _rename,
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Rename'),
                  ),
                if (widget.project.role == 'owner' ||
                    widget.project.role == 'collaborator')
                  TextButton.icon(
                    onPressed: widget.onArchive,
                    icon: const Icon(Icons.archive_outlined),
                    label: const Text('Archive'),
                  ),
              ]),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            Chip(label: Text(widget.workstream.status)),
            Chip(label: Text('Lead: ${widget.workstream.lead}')),
            Chip(label: Text('Queue: ${widget.workstream.queueStatus}')),
          ]),
          const SizedBox(height: 8),
          Text(_timeline.isEmpty
              ? 'No Work yet. Describe what you need, then press Run.'
              : 'Latest Work: ${_timeline.first.status}'),
          if (!_canExecute)
            const Text(
                'Viewer access can read the timeline but cannot run Work.'),
          const SizedBox(height: 12),
          TabBar(
            onTap: (index) => setState(() => _tabIndex = index),
            tabs: const [Tab(text: 'Discuss'), Tab(text: 'Work')],
          ),
          const SizedBox(height: 16),
          if (_tabIndex == 0) _discuss(context) else _work(context),
        ]),
      );

  Widget _discuss(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _ProjectPanel(
          title: 'Brief',
          subtitle: 'The shared context for this Workstream.',
          child: _briefEditor(),
        ),
        _ProjectPanel(
          title: 'Discuss',
          subtitle:
              'Talk with your team here. Send messages to Work when you are ready to ask AI to act.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_discussion.isEmpty)
                const Text('No discussion messages yet.')
              else
                ..._discussion.map((message) => _DiscussionMessageCard(
                      item: message,
                      selected: _selectedDiscussionIds.contains(message.id),
                      onSelected: () => setState(() {
                        if (!_selectedDiscussionIds.add(message.id)) {
                          _selectedDiscussionIds.remove(message.id);
                        }
                      }),
                      onSendToWork: () => _sendToWork([message]),
                    )),
              const SizedBox(height: 12),
              TextField(
                controller: _discussionController,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Message the Workstream',
                  hintText: 'Share context, a decision, or a question.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                FilledButton.icon(
                  onPressed: _sendDiscussion,
                  icon: const Icon(Icons.send),
                  label: const Text('Send message'),
                ),
                if (_selectedDiscussionIds.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => _sendToWork(_discussion
                        .where(
                            (item) => _selectedDiscussionIds.contains(item.id))
                        .toList()),
                    icon: const Icon(Icons.playlist_add),
                    label:
                        Text('Send ${_selectedDiscussionIds.length} to Work'),
                  ),
              ]),
              const SizedBox(height: 8),
              const Text(
                  'Messages can be edited by their author. Edits remain visible in the activity history.'),
            ],
          ),
        ),
        if (_timeline.any((item) => item.status == 'completed'))
          _ProjectPanel(
            title: 'Work completed',
            subtitle: 'A compact activity notification from the Work timeline.',
            child: TextButton.icon(
              onPressed: () => setState(() => _tabIndex = 1),
              icon: const Icon(Icons.open_in_new),
              label: const Text('View Work result'),
            ),
          ),
      ]);

  Widget _briefEditor() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _briefField('Purpose', _briefPurposeController),
          _briefField('State', _briefStateController),
          _briefField('Constraints', _briefConstraintsController),
          _briefField('Expected outcome', _briefOutcomeController),
          const SizedBox(height: 8),
          if (_canExecute)
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                onPressed: () => setState(() => _editingBrief = !_editingBrief),
                icon: Icon(_editingBrief ? Icons.check : Icons.edit),
                label: Text(_editingBrief ? 'Done editing' : 'Edit Brief'),
              ),
              if (_editingBrief)
                const Text(
                    'Changes are local until the Workstream API persists them.'),
            ])
          else
            const Text('Viewer access can read the Brief but cannot edit it.'),
        ],
      );

  Widget _briefField(String label, TextEditingController controller) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: controller,
          enabled: _editingBrief && _canExecute,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  Widget _work(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _WorkComposer(
          requestController: _requestController,
          workflow: _workflow,
          quality: _quality,
          account: _account,
          accountMode: _accountMode,
          workstreamBudget: _workstreamBudget,
          requestEstimate: _requestEstimate,
          model: _model,
          advanced: _advanced,
          references: _references,
          canExecute: _canExecute,
          primaryWorkspace: widget.workstream.primaryWorkspace,
          onWorkflowChanged: (value) => setState(() => _workflow = value),
          onQualityChanged: (value) => setState(() => _quality = value),
          onAccountChanged: (value) => setState(() => _account = value),
          onAccountModeChanged: (value) => setState(() => _accountMode = value),
          onWorkstreamBudgetChanged: (value) =>
              setState(() => _workstreamBudget = value),
          onRequestEstimateChanged: (value) =>
              setState(() => _requestEstimate = value),
          onModelChanged: (value) => setState(() => _model = value),
          onAdvancedChanged: () => setState(() => _advanced = !_advanced),
          onReferencesChanged: () => setState(() => _references = !_references),
          onRun: _runWork,
          onProvisionCheckout: widget.onProvisionCheckout,
        ),
        _ProjectPanel(
          title: 'Context assembled for Work',
          subtitle:
              'Deterministic, bounded context. The full discussion transcript is excluded by default.',
          child: _ContextPreview(context: _buildContext()),
        ),
        _ProjectPanel(
          title: 'Work timeline',
          subtitle:
              'Every request has an explicit status and execution result.',
          child: _timeline.isEmpty
              ? const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        'No Work yet. Describe what you need, then press Run.'),
                    SizedBox(height: 6),
                    Text('Work requests coming next'),
                  ],
                )
              : Column(
                  children: _timeline
                      .map((item) => _WorkTimelineCard(
                            item: item,
                            onCancel: item.status == 'queued' ||
                                    item.status == 'running'
                                ? () =>
                                    setState(() => item.status = 'cancelled')
                                : null,
                            onRespond: item.status == 'needs input'
                                ? () => setState(() => item.status = 'running')
                                : null,
                          ))
                      .toList(),
                ),
        ),
      ]);

  void _runWork() {
    final text = _requestController.text.trim();
    if (!_canExecute || text.isEmpty) return;
    setState(() {
      _timeline.insert(
        0,
        _WorkTimelineItem(
          request: text,
          workflow: _workflow,
          status: 'queued',
          detail: 'Waiting for the Workstream coordinator.',
        ),
      );
      _requestController.clear();
    });
    widget.onRunWork?.call(text);
  }

  void _sendDiscussion() {
    final text = _discussionController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _discussion.insert(
        0,
        _DiscussionItem(
          id: 'message-${DateTime.now().microsecondsSinceEpoch}',
          author: 'You',
          text: text,
        ),
      );
      _discussionController.clear();
    });
  }

  void _sendToWork(List<_DiscussionItem> messages) {
    if (messages.isEmpty) return;
    setState(() {
      _requestController.text = messages.map((item) => item.text).join('\n\n');
      _draftReferences = messages.map((item) => item.text).toList();
      _references = true;
      _selectedDiscussionIds.clear();
      _tabIndex = 1;
    });
  }

  _WorkstreamContext _buildContext() => _WorkstreamContext.build(
        projectInstructions: widget.project.instructions,
        purpose: _briefPurposeController.text,
        state: _briefStateController.text,
        constraints: _briefConstraintsController.text,
        expectedOutcome: _briefOutcomeController.text,
        checkpoint: widget.workstream.currentCheckpoint,
        workRequest: _requestController.text,
        references: _draftReferences,
        artifacts: const [],
        workflowRequirements: _workflowRequirements(_workflow),
      );

  List<String> _workflowRequirements(String workflow) => [
        'Workflow: $workflow',
        'Execution must satisfy the selected Workflow version and result contract.',
      ];
}

class _WorkComposer extends StatelessWidget {
  const _WorkComposer({
    required this.requestController,
    required this.workflow,
    required this.quality,
    required this.account,
    required this.accountMode,
    required this.workstreamBudget,
    required this.requestEstimate,
    required this.model,
    required this.advanced,
    required this.references,
    required this.canExecute,
    required this.primaryWorkspace,
    required this.onWorkflowChanged,
    required this.onQualityChanged,
    required this.onAccountChanged,
    required this.onAccountModeChanged,
    required this.onWorkstreamBudgetChanged,
    required this.onRequestEstimateChanged,
    required this.onModelChanged,
    required this.onAdvancedChanged,
    required this.onReferencesChanged,
    required this.onRun,
    required this.onProvisionCheckout,
  });

  final TextEditingController requestController;
  final String workflow;
  final String quality;
  final String account;
  final String accountMode;
  final String workstreamBudget;
  final String requestEstimate;
  final String model;
  final bool advanced;
  final bool references;
  final bool canExecute;
  final String primaryWorkspace;
  final ValueChanged<String> onWorkflowChanged;
  final ValueChanged<String> onQualityChanged;
  final ValueChanged<String> onAccountChanged;
  final ValueChanged<String> onAccountModeChanged;
  final ValueChanged<String> onWorkstreamBudgetChanged;
  final ValueChanged<String> onRequestEstimateChanged;
  final ValueChanged<String> onModelChanged;
  final VoidCallback onAdvancedChanged;
  final VoidCallback onReferencesChanged;
  final VoidCallback onRun;
  final VoidCallback onProvisionCheckout;

  @override
  Widget build(BuildContext context) => _ProjectPanel(
        title: 'Work',
        subtitle:
            'Ask AI to do something for the team. Nothing runs until you press Run.',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: requestController,
            minLines: 3,
            maxLines: 6,
            enabled: canExecute,
            decoration: const InputDecoration(
              labelText: 'What should Conclave do?',
              hintText:
                  'Example: Investigate the login failure and propose a fix.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: workflow,
            decoration: const InputDecoration(labelText: 'Workflow'),
            items: const [
              DropdownMenuItem(value: 'Research', child: Text('Research')),
              DropdownMenuItem(value: 'Review', child: Text('Review')),
              DropdownMenuItem(
                  value: 'Implementation', child: Text('Implementation')),
              DropdownMenuItem(
                  value: 'Implementation + Test + Review',
                  child: Text('Implementation + Test + Review')),
              DropdownMenuItem(
                  value: 'Research + Implementation',
                  child: Text('Research + Implementation')),
              DropdownMenuItem(value: 'Full Cycle', child: Text('Full Cycle')),
            ],
            onChanged: canExecute
                ? (value) {
                    if (value != null) onWorkflowChanged(value);
                  }
                : null,
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            OutlinedButton.icon(
              onPressed: onReferencesChanged,
              icon: Icon(references ? Icons.link : Icons.add_link),
              label: Text(references ? 'References added' : 'Add references'),
            ),
            TextButton.icon(
              onPressed: onAdvancedChanged,
              icon: Icon(advanced ? Icons.expand_less : Icons.tune),
              label: const Text('Advanced'),
            ),
          ]),
          if (advanced)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Advanced controls',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 12, runSpacing: 12, children: [
                      SizedBox(
                          width: 180,
                          child: _select(
                              'Account policy',
                              accountMode,
                              const [
                                'requester',
                                'sponsor',
                                'project_shared',
                                'explicit_accounts',
                                'auto_authorized'
                              ],
                              onAccountModeChanged)),
                      SizedBox(
                          width: 180,
                          child: _select(
                              'Account override',
                              account,
                              const ['Auto', 'Project account'],
                              onAccountChanged)),
                      SizedBox(
                          width: 180,
                          child: _select(
                              'Workstream budget',
                              workstreamBudget,
                              const ['No budget', '100 credits', '500 credits'],
                              onWorkstreamBudgetChanged)),
                      SizedBox(
                          width: 180,
                          child: _select(
                              'Request estimate',
                              requestEstimate,
                              const [
                                'Auto estimate',
                                '10 credits',
                                '50 credits'
                              ],
                              onRequestEstimateChanged)),
                      SizedBox(
                          width: 180,
                          child: _select(
                              'Model',
                              model,
                              const ['Auto', 'Best available'],
                              onModelChanged)),
                      SizedBox(
                          width: 180,
                          child: _select(
                              'Quality',
                              quality,
                              const ['Economy', 'Balanced', 'High assurance'],
                              onQualityChanged)),
                      SizedBox(
                          width: 220,
                          child: TextFormField(
                              initialValue: primaryWorkspace,
                              enabled: false,
                              decoration: const InputDecoration(
                                  labelText: 'Primary Workspace'))),
                    ]),
                    const SizedBox(height: 8),
                    const Text(
                        'Sponsor mode may use only Accounts authorized by an existing Project Account Grant. Workstream policy can narrow that grant but cannot create one.'),
                    const SizedBox(height: 4),
                    const Text(
                        'Usage records both the requester and Account owner. Provider private-only rules and Account installation on the Primary Workspace remain authoritative.'),
                    const SizedBox(height: 8),
                    const Text(
                        'Worker is selected by the workflow and Workspace capability. There is no Workstream-level Worker default.'),
                  ]),
            ),
          const SizedBox(height: 12),
          Wrap(spacing: 10, children: [
            FilledButton.icon(
              onPressed: canExecute ? onRun : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Run'),
            ),
            OutlinedButton.icon(
              onPressed: canExecute ? onProvisionCheckout : null,
              icon: const Icon(Icons.inventory_2_outlined),
              label: const Text('Prepare workspace'),
            ),
          ]),
          if (!canExecute)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                  'Viewer access can read the timeline but cannot run Work.'),
            ),
        ]),
      );

  Widget _select(String label, String value, List<String> values,
          ValueChanged<String> onChanged) =>
      DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: values
            .map((item) => DropdownMenuItem(value: item, child: Text(item)))
            .toList(),
        onChanged: (next) {
          if (next != null) onChanged(next);
        },
      );
}

class _WorkTimelineItem {
  _WorkTimelineItem(
      {required this.request,
      required this.workflow,
      required this.status,
      required this.detail});
  final String request;
  final String workflow;
  String status;
  final String detail;
}

class _WorkstreamContext {
  const _WorkstreamContext(this.sections);

  final List<MapEntry<String, String>> sections;

  factory _WorkstreamContext.build({
    required String projectInstructions,
    required String purpose,
    required String state,
    required String constraints,
    required String expectedOutcome,
    required String checkpoint,
    required String workRequest,
    required List<String> references,
    required List<String> artifacts,
    required List<String> workflowRequirements,
  }) {
    final entries = <MapEntry<String, String>>[
      MapEntry('Project instructions', _bounded(projectInstructions)),
      MapEntry('Brief · purpose', _bounded(purpose)),
      MapEntry('Brief · state', _bounded(state)),
      MapEntry('Brief · constraints', _bounded(constraints)),
      MapEntry('Brief · expected outcome', _bounded(expectedOutcome)),
      MapEntry('Current checkpoint', _bounded(checkpoint)),
      MapEntry(
          'Work Request',
          _bounded(
              workRequest.isEmpty ? 'Draft not yet written.' : workRequest)),
      MapEntry(
          'Discuss references',
          references.isEmpty
              ? 'None explicitly selected.'
              : references.map(_bounded).join('\n')),
      MapEntry(
          'Explicit artifacts',
          artifacts.isEmpty
              ? 'None explicitly selected.'
              : artifacts.map(_bounded).join('\n')),
      MapEntry('Workflow requirements',
          workflowRequirements.map(_bounded).join('\n')),
    ];
    return _WorkstreamContext(entries);
  }

  static String _bounded(String value) {
    final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    return normalized.length <= 240
        ? normalized
        : '${normalized.substring(0, 237)}...';
  }
}

class _ContextPreview extends StatelessWidget {
  const _ContextPreview({required this.context});
  final _WorkstreamContext context;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: this
            .context
            .sections
            .map((section) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: RichText(
                    text: TextSpan(
                      style: DefaultTextStyle.of(context).style,
                      children: [
                        TextSpan(
                            text: '${section.key}: ',
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        TextSpan(text: section.value),
                      ],
                    ),
                  ),
                ))
            .toList(),
      );
}

class _DiscussionItem {
  const _DiscussionItem(
      {required this.id, required this.author, required this.text});
  final String id;
  final String author;
  final String text;
}

class _DiscussionMessageCard extends StatelessWidget {
  const _DiscussionMessageCard({
    required this.item,
    required this.selected,
    required this.onSelected,
    required this.onSendToWork,
  });

  final _DiscussionItem item;
  final bool selected;
  final VoidCallback onSelected;
  final VoidCallback onSendToWork;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Checkbox(value: selected, onChanged: (_) => onSelected()),
              Expanded(
                  child: Text(item.author,
                      style: const TextStyle(fontWeight: FontWeight.w600))),
              TextButton(
                  onPressed: onSendToWork, child: const Text('Send to Work')),
            ]),
            Text(item.text),
            const SizedBox(height: 4),
            const Text('References · Reply · Edit'),
          ]),
        ),
      );
}

class _WorkTimelineCard extends StatelessWidget {
  const _WorkTimelineCard(
      {required this.item, required this.onCancel, required this.onRespond});
  final _WorkTimelineItem item;
  final VoidCallback? onCancel;
  final VoidCallback? onRespond;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, children: [
              Chip(label: Text(item.status)),
              Chip(label: Text(item.workflow)),
            ]),
            Text(item.request,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(item.detail),
            if (item.status == 'completed')
              const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('Checkpoint · Changes · Tests · Findings')),
            if (onRespond != null)
              TextButton(
                  onPressed: onRespond, child: const Text('Provide input')),
            if (onCancel != null)
              TextButton(onPressed: onCancel, child: const Text('Cancel Work')),
          ]),
        ),
      );
}

class _ProjectPanel extends StatelessWidget {
  const _ProjectPanel({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 5),
              Text(subtitle,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 16),
              child,
            ],
          ),
        ),
      );
}
