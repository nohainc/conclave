import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../studio/studio_data.dart';
import '../../studio/studio_models.dart';
import '../../studio/work_request_file_picker_stub.dart'
    if (dart.library.html) '../../studio/work_request_file_picker_web.dart'
    as work_request_files;

class ProjectPage extends StatelessWidget {
  const ProjectPage({
    super.key,
    required this.project,
    required this.dataSource,
    required this.onOpenWorkstream,
    this.onOpenWorkspace,
    this.onEdit,
    required this.onArchive,
    required this.onDelete,
    this.onProjectUpdated,
  });

  final StudioProject project;
  final StudioDataSource dataSource;
  final ValueChanged<String> onOpenWorkstream;
  final ValueChanged<String>? onOpenWorkspace;
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
        onOpenWorkspace: onOpenWorkspace,
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
    this.onOpenWorkspace,
    this.onEdit,
    required this.onArchive,
    required this.onDelete,
    this.onProjectUpdated,
  });

  final StudioProject project;
  final StudioDataSource dataSource;
  final ValueChanged<String> onOpenWorkstream;
  final ValueChanged<String>? onOpenWorkspace;
  final VoidCallback? onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final ValueChanged<StudioProject>? onProjectUpdated;

  @override
  State<_ProjectWorkspace> createState() => _ProjectWorkspaceState();
}

class _ProjectWorkspaceState extends State<_ProjectWorkspace>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
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
  late TextEditingController _instructionsController;

  bool get canManage =>
      widget.project.role == 'owner' || widget.project.role == 'collaborator';
  bool get isOwner => widget.project.role == 'owner';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _nameController = TextEditingController(text: widget.project.name);
    _descriptionController =
        TextEditingController(text: widget.project.description);
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
        oldWidget.project.instructions != widget.project.instructions) {
      if (_editingField == null) {
        _nameController.text = widget.project.name;
        _descriptionController.text = widget.project.description;
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
    _tabController.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
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
        instructions: _instructionsController.text.trim(),
        settings: widget.project.settings,
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
          'Connect a Workspace first. You can grant it access to this Project later.');
      return;
    }
    var selectedId = ownedWorkspaces.first.id;
    String? errorText;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            final alreadyConnected = projectWorkspaces.any((pw) {
              final pwId = (pw['workspaceId'] ?? pw['id'] ?? '').toString();
              return pwId == selectedId;
            });
            if (alreadyConnected) {
              setDialogState(() {
                errorText =
                    'This Workspace is already connected to this Project.';
              });
              return;
            }
            Navigator.pop(dialogContext, true);
          }

          return AlertDialog(
            title: const Text('Connect Workspace'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: selectedId,
                  decoration: InputDecoration(
                    labelText: 'Workspace',
                    errorText: errorText,
                  ),
                  items: ownedWorkspaces
                      .map((workspace) => DropdownMenuItem(
                            value: workspace.id,
                            child: Text(workspace.name),
                          ))
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() {
                        selectedId = value;
                        errorText = null;
                      });
                    }
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: submit,
                child: const Text('Connect'),
              ),
            ],
          );
        },
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
    final name =
        (workspace['workspaceName'] ?? workspace['name'] ?? 'Workspace')
            .toString();
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
    var name = '';
    String? errorText;
    final created = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            final trimmed = name.trim();
            if (trimmed.isEmpty) return;
            final exists = workstreams.any(
              (w) => w.name.trim().toLowerCase() == trimmed.toLowerCase(),
            );
            if (exists) {
              setDialogState(() {
                errorText = 'A workstream with this name already exists.';
              });
              return;
            }
            Navigator.pop(dialogContext, trimmed);
          }

          return AlertDialog(
            title: const Text('Create Workstream'),
            content: TextField(
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Workstream name',
                errorText: errorText,
              ),
              onChanged: (value) {
                name = value;
                if (errorText != null) {
                  setDialogState(() => errorText = null);
                }
              },
              onSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: submit,
                child: const Text('Create Workstream'),
              ),
            ],
          );
        },
      ),
    );
    if (created == null || created.isEmpty) return;
    try {
      final workstream = await widget.dataSource.createWorkstream(
        projectId: widget.project.id,
        name: created,
      );
      if (!mounted) return;
      setState(() => workstreams = [...workstreams, workstream]);
      widget.onOpenWorkstream(workstream.id);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _editWorkstream(StudioWorkstream workstream) async {
    var name = workstream.name;
    String? errorText;
    final updatedName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            final trimmed = name.trim();
            if (trimmed.isEmpty) return;
            final exists = workstreams.any(
              (w) =>
                  w.id != workstream.id &&
                  w.name.trim().toLowerCase() == trimmed.toLowerCase(),
            );
            if (exists) {
              setDialogState(() {
                errorText = 'A workstream with this name already exists.';
              });
              return;
            }
            Navigator.pop(dialogContext, trimmed);
          }

          return AlertDialog(
            title: const Text('Edit Workstream'),
            content: TextFormField(
              initialValue: workstream.name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Workstream name',
                errorText: errorText,
              ),
              onChanged: (value) {
                name = value;
                if (errorText != null) {
                  setDialogState(() => errorText = null);
                }
              },
              onFieldSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: submit,
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    if (updatedName == null ||
        updatedName.isEmpty ||
        updatedName == workstream.name) {
      return;
    }
    try {
      final updated = await widget.dataSource.updateWorkstream(
        workstreamId: workstream.id,
        name: updatedName,
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

  Future<void> _setWorkstreamArchived(
    StudioWorkstream workstream,
    bool archived,
  ) async {
    try {
      final updated = await widget.dataSource.updateWorkstream(
        workstreamId: workstream.id,
        status: archived ? 'archived' : 'active',
      );
      if (!mounted) return;
      setState(() {
        workstreams = workstreams
            .map((item) => item.id == updated.id ? updated : item)
            .toList();
      });
      _message(archived ? 'Workstream archived.' : 'Workstream restored.');
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

  void _message(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 4),
          showCloseIcon: true,
          closeIconColor: const Color(0xff9e9ea7),
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
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
            },
          ),
        ),
      );

    Future<void>.delayed(const Duration(seconds: 4), () {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
      }
    });
  }

  Future<void> _share() async {
    var email = '';
    var role = 'collaborator';
    String? errorText;
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            final trimmedEmail = email.trim();
            if (trimmedEmail.isEmpty) return;
            final normalized = trimmedEmail.toLowerCase();
            final isAlreadyMember = members.any(
              (m) => m.email.trim().toLowerCase() == normalized,
            );
            if (isAlreadyMember) {
              setDialogState(() {
                errorText = 'This user is already a member of the Project.';
              });
              return;
            }
            final isAlreadyInvited = invitations.any(
              (i) => i.email.trim().toLowerCase() == normalized,
            );
            if (isAlreadyInvited) {
              setDialogState(() {
                errorText = 'An invitation was already sent to this email.';
              });
              return;
            }
            Navigator.pop(dialogContext, (trimmedEmail, role));
          }

          return AlertDialog(
            title: const Text('Share Project'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: 'Email address',
                    errorText: errorText,
                  ),
                  onChanged: (value) {
                    email = value;
                    if (errorText != null) {
                      setDialogState(() => errorText = null);
                    }
                  },
                  onSubmitted: (_) => submit(),
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
                  onChanged: (value) =>
                      setDialogState(() => role = value ?? role),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: submit,
                child: const Text('Send invitation'),
              ),
            ],
          );
        },
      ),
    );
    if (result == null || result.$1.isEmpty) return;
    try {
      await widget.dataSource.inviteProjectMember(
          projectId: widget.project.id, email: result.$1, role: result.$2);
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
                textInputAction: maxLines == 1
                    ? TextInputAction.done
                    : TextInputAction.newline,
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
                // Project instructions
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
          AnimatedBuilder(
            animation: _tabController,
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: TabBar(
                    controller: _tabController,
                    isScrollable: true,
                    tabAlignment: TabAlignment.center,
                    tabs: const [
                      Tab(text: 'Workstreams'),
                      Tab(text: 'Workspaces'),
                      Tab(text: 'Members'),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (_tabController.index == 0)
                  _workstreamsTab()
                else if (_tabController.index == 1)
                  _workspacesTab()
                else
                  _membersTab(),
              ],
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
                children: [
                  ...workstreams
                      .asMap()
                      .entries
                      .where((entry) => entry.value.status != 'archived')
                      .map((entry) {
                    final index = entry.key;
                    final workstream = entry.value;
                    return _workstreamListTile(workstream, index);
                  }),
                  if (workstreams.any((item) => item.status == 'archived')) ...[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Archived Workstreams',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    ...workstreams
                        .where((item) => item.status == 'archived')
                        .map((workstream) => _workstreamListTile(
                              workstream,
                              workstreams.indexOf(workstream),
                            )),
                  ],
                ],
              ),
          ],
        ),
      );

  Widget _workstreamListTile(StudioWorkstream workstream, int index) {
    final archived = workstream.status == 'archived';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        workstream.name,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
      onTap: archived ? null : () => widget.onOpenWorkstream(workstream.id),
      trailing: canManage
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!archived)
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_up_rounded),
                    tooltip: 'Move up',
                    iconSize: 20,
                    splashRadius: 16,
                    onPressed:
                        index > 0 ? () => _moveWorkstream(index, -1) : null,
                  ),
                if (!archived)
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
                    } else if (action == 'archive') {
                      _setWorkstreamArchived(workstream, true);
                    } else if (action == 'restore') {
                      _setWorkstreamArchived(workstream, false);
                    } else if (action == 'delete') {
                      _deleteWorkstream(workstream);
                    }
                  },
                  itemBuilder: (context) => [
                    if (!archived)
                      const PopupMenuItem(
                        value: 'edit',
                        child: Text('Rename'),
                      ),
                    PopupMenuItem(
                      value: archived ? 'restore' : 'archive',
                      child: Text(archived ? 'Restore' : 'Archive'),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete'),
                    ),
                  ],
                ),
              ],
            )
          : null,
    );
  }

  Widget _workspacesTab() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    'Workspaces provide execution capacity for your project.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (canManage)
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'Connect Workspace',
                    splashRadius: 20,
                    onPressed: _connectWorkspace,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (executionLoading)
              const LinearProgressIndicator()
            else if (projectWorkspaces.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No execution workspaces connected yet.'),
              )
            else
              Column(
                children: projectWorkspaces.map((workspace) {
                  final workspaceName = (workspace['workspaceName'] ??
                          workspace['name'] ??
                          workspace['workspaceId'] ??
                          'Workspace')
                      .toString();
                  final workspaceId =
                      (workspace['workspaceId'] ?? workspace['id'] ?? '')
                          .toString();
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      workspaceName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    onTap: () {
                      if (widget.onOpenWorkspace != null) {
                        widget.onOpenWorkspace!(workspaceId);
                      }
                    },
                    trailing: isOwner
                        ? IconButton(
                            icon: const Icon(Icons.link_off, size: 18),
                            tooltip: 'Revoke grant',
                            onPressed: () => _revokeWorkspaceGrant(workspace),
                          )
                        : null,
                  );
                }).toList(),
              ),
          ],
        ),
      );

  Widget _membersTab() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    'Project roles control collaboration across team members.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (isOwner)
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'Share Project',
                    splashRadius: 20,
                    onPressed: _share,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (loading)
              const LinearProgressIndicator()
            else if (members.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No members found.'),
              )
            else
              Column(
                children: [
                  ...members.map((member) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          member.displayName.isNotEmpty
                              ? member.displayName
                              : member.email,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        subtitle: member.displayName.isNotEmpty &&
                                member.email.isNotEmpty &&
                                member.displayName != member.email
                            ? Text(member.email)
                            : null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Chip(label: Text(member.role)),
                            if (isOwner && member.role != 'owner') ...[
                              const SizedBox(width: 4),
                              PopupMenuButton<String>(
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
                                    child: Text('Change role'),
                                  ),
                                  PopupMenuItem(
                                    value: 'remove',
                                    child: Text('Remove from Project'),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      )),
                  if (invitations.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Pending invitations',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ...invitations.map((invite) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            invite.email,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Chip(label: Text('Pending')),
                              if (isOwner) ...[
                                const SizedBox(width: 4),
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
    this.dataSource,
    this.currentUserId,
    required this.onBackToProject,
    required this.onArchive,
    required this.onProvisionCheckout,
    this.onRename,
    this.onRunWork,
    this.realtimeEvents,
    this.initialTab = 0,
  });

  final StudioProject project;
  final StudioWorkstream workstream;
  final StudioDataSource? dataSource;
  final String? currentUserId;
  final VoidCallback onBackToProject;
  final VoidCallback onArchive;
  final VoidCallback onProvisionCheckout;
  final Future<void> Function(String name)? onRename;
  final Future<String> Function(String prompt, String workflowId,
      List<Map<String, dynamic>> attachments)? onRunWork;
  final Stream<Map<String, dynamic>>? realtimeEvents;
  final int initialTab;

  @override
  State<WorkstreamPage> createState() => _WorkstreamPageState();
}

class _WorkstreamPageState extends State<WorkstreamPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _requestController = TextEditingController();
  final _discussionController = TextEditingController();
  late final TextEditingController _workstreamInstructionsController;
  String _workflow = '';
  List<StudioBuiltinWorkflow> _workflowCatalog = const [];
  bool _loadingWorkflows = true;
  String? _workflowCatalogError;
  final List<_DiscussionItem> _discussion = [];
  List<StudioWorkRequest> _workTimeline = const [];
  bool _loadingWorkTimeline = true;
  bool _refreshingWorkTimeline = false;
  bool _workTimelineRefreshPending = false;
  String? _workTimelineError;
  String? _workSubmitError;
  StreamSubscription<Map<String, dynamic>>? _workEventSubscription;
  bool _submittingWork = false;
  List<Map<String, dynamic>> _workAttachments = [];
  List<StudioWorker> _projectWorkers = const [];
  List<StudioWorker> _eligibleWorkers = const [];
  Map<String, String> _projectWorkspaceNames = const {};
  late Map<String, dynamic> _workConfig;
  bool _loadingWorkChoices = true;
  bool _savingWorkConfig = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      initialIndex: widget.initialTab.clamp(0, 2),
      vsync: this,
    );
    _workConfig = Map<String, dynamic>.from(widget.workstream.workConfig);
    _workstreamInstructionsController = TextEditingController(
      text: _workConfig['workstreamInstructions']?.toString() ?? '',
    );
    _loadDiscussion();
    _refreshWorkTimeline();
    _subscribeToWorkEvents();
    _loadWorkChoices();
    _loadWorkflowCatalog();
  }

  Future<void> _loadWorkflowCatalog() async {
    final ds = widget.dataSource;
    if (ds == null) {
      setState(() {
        _loadingWorkflows = false;
        _workflowCatalogError = 'Workflow catalog is unavailable.';
      });
      return;
    }
    try {
      final workflows = await ds.loadBuiltinWorkflowCatalog();
      if (!mounted) return;
      setState(() {
        _workflowCatalog = workflows;
        _loadingWorkflows = false;
        _workflowCatalogError =
            workflows.isEmpty ? 'No built-in Workflows are available.' : null;
        _workflow =
            workflows.isEmpty ? '' : _workstreamDefaultReference(workflows);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingWorkflows = false;
        _workflowCatalogError = 'Could not load the Workflow catalog.';
      });
    }
  }

  String _workstreamDefaultReference(List<StudioBuiltinWorkflow> workflows) {
    if (workflows.isEmpty) return '';
    final defaultId = _workConfig['defaultWorkflowId']?.toString();
    return workflows
            .where((workflow) => workflow.id == defaultId)
            .map((workflow) => workflow.reference)
            .firstOrNull ??
        workflows.first.reference;
  }

  Future<void> _loadWorkChoices() async {
    final ds = widget.dataSource;
    if (ds == null) {
      setState(() => _loadingWorkChoices = false);
      return;
    }
    try {
      final loaded = await Future.wait([
        ds.loadWorkspaceWorkerInventory(),
        ds.loadProjectWorkspaces(projectId: widget.project.id),
      ]);
      if (!mounted) return;
      final grants = loaded[1] as List<Map<String, dynamic>>;
      final names = <String, String>{};
      for (final grant in grants) {
        final id = (grant['workspaceId'] ?? grant['id'] ?? '').toString();
        if (id.isEmpty) continue;
        names[id] = (grant['workspaceName'] ?? grant['name'] ?? id).toString();
      }
      setState(() {
        _projectWorkers = (loaded[0] as List<StudioWorker>)
            .where((worker) => names.containsKey(worker.workspaceId))
            .toList();
        _eligibleWorkers = _projectWorkers
            .where((worker) =>
                worker.activationState == 'enabled' &&
                worker.readinessState == 'ready')
            .toList();
        _projectWorkspaceNames = names;
        _loadingWorkChoices = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingWorkChoices = false);
    }
  }

  Future<void> _loadDiscussion() async {
    final ds = widget.dataSource;
    if (ds == null) return;
    try {
      final messages =
          await ds.loadDiscussionMessages(workstreamId: widget.workstream.id);
      if (!mounted) return;
      setState(() {
        _discussion
          ..clear()
          ..addAll(messages.map((m) {
            final dt = DateTime.tryParse(m.createdAt)?.toLocal();
            final timeStr = dt != null
                ? '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}'
                : null;
            final isMe = widget.currentUserId != null &&
                widget.currentUserId!.isNotEmpty &&
                m.authorUserId == widget.currentUserId;
            return _DiscussionItem(
              id: m.id,
              author: isMe ? 'You' : (m.authorName ?? 'Member'),
              text: m.body,
              sentAt: timeStr,
              isMe: isMe,
            );
          }));
      });
    } catch (_) {
      // Ignore network errors on initial load
    }
  }

  @override
  void didUpdateWidget(WorkstreamPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      _tabController.animateTo(widget.initialTab.clamp(0, 2));
    }
    if (oldWidget.workstream.workConfig != widget.workstream.workConfig) {
      _workConfig = Map<String, dynamic>.from(widget.workstream.workConfig);
      _workstreamInstructionsController.text =
          _workConfig['workstreamInstructions']?.toString() ?? '';
      if (_workflowCatalog.isNotEmpty) {
        _workflow = _workstreamDefaultReference(_workflowCatalog);
      }
    }
    if (oldWidget.realtimeEvents != widget.realtimeEvents) {
      _workEventSubscription?.cancel();
      _subscribeToWorkEvents();
    }
  }

  void _subscribeToWorkEvents() {
    _workEventSubscription = widget.realtimeEvents?.listen((event) {
      final type = event['type'];
      if (type == 'reconnect.required') {
        unawaited(_refreshWorkTimeline());
        return;
      }
      if (type is! String ||
          !(type.startsWith('work_request.') || type.startsWith('step.'))) {
        return;
      }
      final payload = event['payload'];
      if (payload is! Map || payload['workstreamId'] != widget.workstream.id) {
        return;
      }
      unawaited(_refreshWorkTimeline(activeOnly: true));
    });
  }

  bool get _canExecute =>
      widget.project.role == 'owner' || widget.workstream.canExecuteWork;
  bool get _canConfigureWork =>
      widget.project.role == 'owner' || widget.workstream.canConfigureWork;

  @override
  void dispose() {
    _workEventSubscription?.cancel();
    _tabController.dispose();
    _requestController.dispose();
    _discussionController.dispose();
    _workstreamInstructionsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _tabController,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                tabAlignment: TabAlignment.center,
                tabs: const [
                  Tab(text: 'Discuss'),
                  Tab(text: 'Work'),
                  Tab(text: 'Execution'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_tabController.index == 0)
              _discuss(context)
            else if (_tabController.index == 1)
              _work(context),
            if (_tabController.index == 2) _workConfigView(),
          ],
        ),
      );

  Widget _discuss(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_discussion.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
            alignment: Alignment.center,
            child: Column(
              children: [
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 42,
                  color: isDark ? Colors.white24 : Colors.black26,
                ),
                const SizedBox(height: 12),
                Text(
                  'No discussion messages yet',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Share context, decisions, or questions with your team below.',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ),
              ],
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _discussion.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final message = _discussion[index];
              return _DiscussionMessageBubble(
                key: ValueKey(message.id),
                item: message,
                onCopy: () {
                  Clipboard.setData(ClipboardData(text: message.text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Message copied to clipboard'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                onEdit: (newText) => _editDiscussion(message.id, newText),
              );
            },
          ),
        const SizedBox(height: 16),
        _DiscussionInputBox(
          controller: _discussionController,
          onSend: _sendDiscussion,
        ),
      ],
    );
  }

  Widget _work(BuildContext context) => _WorkComposer(
        requestController: _requestController,
        workflow: _workflow,
        workflowCatalog: _workflowCatalog,
        loadingWorkflows: _loadingWorkflows,
        workflowCatalogError: _workflowCatalogError,
        canExecute: _canExecute,
        workTimeline: _workTimeline,
        loadingTimeline: _loadingWorkTimeline,
        timelineError: _workTimelineError,
        submitError: _workSubmitError,
        submitting: _submittingWork,
        attachments: _workAttachments,
        onAddFiles: _addWorkFiles,
        onAddReference: _addWorkReference,
        onRemoveAttachment: (index) => setState(() {
          _workAttachments.removeAt(index);
        }),
        onRefresh: _refreshWorkTimeline,
        onShowRunDetails: widget.dataSource == null ? null : _showRunDetails,
        onRetryStep: widget.dataSource == null ? null : _retryWorkRequestStep,
        onCancelRun:
            widget.dataSource == null ? null : _cancelFailedWorkRequest,
        onWorkflowChanged: (value) => setState(() => _workflow = value),
        onRun: _runWork,
      );

  Widget _workConfigView() {
    final bindings = _workConfig['bindings'] is Map
        ? Map<String, dynamic>.from(_workConfig['bindings'] as Map)
        : <String, dynamic>{};
    final defaultWorkflowId = _workConfig['defaultWorkflowId']?.toString() ??
        _workflowCatalog.firstOrNull?.id ??
        '';
    final chatgptWorker = _preferredReadyWorker('chatgpt');
    final geminiWorker = _preferredReadyWorker('gemini');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Execution', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        Text('Default workflow', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (_loadingWorkflows)
          const LinearProgressIndicator()
        else if (_workflowCatalog.isNotEmpty)
          DropdownButtonFormField<String>(
            itemHeight: null,
            initialValue: defaultWorkflowId,
            decoration: const InputDecoration(labelText: 'Default Workflow'),
            items: _workflowCatalog
                .map((workflow) => DropdownMenuItem(
                      value: workflow.id,
                      child: _workflowOption(context, workflow),
                    ))
                .toList(),
            onChanged: !_canConfigureWork || _savingWorkConfig
                ? null
                : (value) {
                    if (value != null) {
                      setState(() => _workConfig = {
                            ..._workConfig,
                            'defaultWorkflowId': value,
                          });
                    }
                  },
          ),
        const SizedBox(height: 12),
        Text('Workers', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (_loadingWorkChoices)
          const LinearProgressIndicator()
        else ...[
          if (_projectWorkers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Grant a Workspace to this Project and install a Worker to configure Steps.',
              ),
            )
          else if (_eligibleWorkers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No Workers are Ready yet. Check sign-in and enablement in Workspace settings.',
              ),
            ),
          if (bindings.isEmpty && chatgptWorker != null && geminiWorker != null)
            _recommendedSetupCard(chatgptWorker, geminiWorker),
          if (bindings.isEmpty && chatgptWorker != null && geminiWorker == null)
            _singleWorkerSetupCard(chatgptWorker),
          if (bindings.isEmpty && geminiWorker != null && chatgptWorker == null)
            _singleWorkerSetupCard(geminiWorker),
          ...const [
            'direct',
            'research',
            'plan',
            'implement',
            'test',
            'verify',
          ].map((bindingId) {
            final raw = bindings[bindingId];
            final binding = raw is Map
                ? Map<String, dynamic>.from(raw)
                : <String, dynamic>{};
            final configuredWorkerId = binding['workerId']?.toString() ?? '';
            final selectedId = _eligibleWorkers
                    .any((worker) => worker.id == configuredWorkerId)
                ? configuredWorkerId
                : '';
            final selectedWorker = _projectWorkers
                .where((worker) => worker.id == configuredWorkerId)
                .firstOrNull;
            final status = selectedWorker == null
                ? (configuredWorkerId.isEmpty ? 'Not assigned' : 'Unavailable')
                : _workerReadinessLabel(selectedWorker);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                      width: 100, child: Text(_stepDisplayName(bindingId))),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: selectedId,
                      decoration: const InputDecoration(
                        labelText: 'Worker',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('Choose a Worker'),
                        ),
                        ..._eligibleWorkers.map((worker) => DropdownMenuItem(
                              value: worker.id,
                              child: Text(
                                '${_workerDisplayName(worker)} · ${_projectWorkspaceNames[worker.workspaceId] ?? worker.workspaceId}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            )),
                      ],
                      onChanged: !_canConfigureWork || _savingWorkConfig
                          ? null
                          : (value) => _setStepBinding(
                                bindingId,
                                value == null || value.isEmpty
                                    ? <String, dynamic>{}
                                    : {...binding, 'workerId': value},
                              ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 110,
                    child: Text(
                      status,
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: status == 'Ready'
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.error,
                          ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
        const SizedBox(height: 12),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Advanced'),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Project instructions',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(widget.project.instructions.trim().isEmpty
                  ? 'None set'
                  : widget.project.instructions),
            ),
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Edit these in Project settings.'),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _workstreamInstructionsController,
              minLines: 2,
              maxLines: 5,
              maxLength: 4000,
              enabled: _canConfigureWork && !_savingWorkConfig,
              decoration: const InputDecoration(
                labelText: 'Workstream instructions',
                helperText: 'Applied to every Step.',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _workConfig = {
                    ..._workConfig,
                    'workstreamInstructions': value,
                  }),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Step settings',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            ...const [
              'direct',
              'research',
              'plan',
              'implement',
              'test',
              'verify',
            ].map((bindingId) {
              final raw = bindings[bindingId];
              final binding = raw is Map
                  ? Map<String, dynamic>.from(raw)
                  : <String, dynamic>{};
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_stepDisplayName(bindingId)),
                subtitle: Text(_stepAdvancedSummary(binding)),
                trailing: TextButton(
                  onPressed: !_canConfigureWork || _savingWorkConfig
                      ? null
                      : () => _editStepBinding(bindingId, binding),
                  child: const Text('Configure'),
                ),
              );
            }),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Concurrency'),
              subtitle: Text('Work Requests are queued for this Workstream.'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: !_canConfigureWork || _savingWorkConfig
              ? null
              : () => _saveWorkConfig(_workConfig),
          icon: _savingWorkConfig
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save_outlined),
          label: const Text('Save Work settings'),
        ),
        if (!_canConfigureWork)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
                'Only the Project owner or assigned Workstream lead can change Work settings.'),
          ),
      ],
    );
  }

  String _stepDisplayName(String bindingId) => switch (bindingId) {
        'direct' => 'Direct',
        'research' => 'Research',
        'plan' => 'Plan',
        'implement' => 'Implement',
        'test' => 'Test',
        _ => 'Verify',
      };

  String _workerReadinessLabel(StudioWorker worker) {
    if (worker.activationState != 'enabled') return 'Disabled';
    if (worker.readinessState == 'ready') return 'Ready';
    if (worker.attentionReasonCode == 'sign_in_required' ||
        worker.readinessState == 'sign_in_required') {
      return 'Needs sign-in';
    }
    return 'Needs attention';
  }

  String _stepAdvancedSummary(Map<String, dynamic> binding) {
    final details = <String>[];
    if ((binding['additionalInstructions']?.toString().trim().isNotEmpty ??
        false)) {
      details.add('Step instructions');
    }
    if ((binding['model']?.toString().trim().isNotEmpty ?? false)) {
      details.add('Model: ${binding['model']}');
    }
    if ((binding['fallbackWorkerId']?.toString().trim().isNotEmpty ?? false)) {
      details.add('Fallback set');
    }
    return details.isEmpty
        ? 'Instructions, model, and fallback'
        : details.join(' · ');
  }

  StudioWorker? _preferredReadyWorker(String workerTypeId) {
    final matching = _eligibleWorkers
        .where((worker) => worker.workerTypeId == workerTypeId)
        .toList()
      ..sort((a, b) {
        final workspaceCompare = (_projectWorkspaceNames[a.workspaceId] ?? '')
            .compareTo(_projectWorkspaceNames[b.workspaceId] ?? '');
        if (workspaceCompare != 0) return workspaceCompare;
        return a.id.compareTo(b.id);
      });
    return matching.firstOrNull;
  }

  Widget _recommendedSetupCard(
    StudioWorker chatgptWorker,
    StudioWorker geminiWorker,
  ) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Set up Work',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              const Text('Recommended'),
              const SizedBox(height: 12),
              ...const [
                ('Direct', 'chatgpt'),
                ('Research', 'gemini'),
                ('Plan', 'gemini'),
                ('Implement', 'chatgpt'),
                ('Test', 'chatgpt'),
                ('Verify', 'gemini'),
              ].map((step) {
                final worker =
                    step.$2 == 'chatgpt' ? chatgptWorker : geminiWorker;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(child: Text(step.$1)),
                      Text(_workerDisplayName(worker)),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: !_canConfigureWork || _savingWorkConfig
                    ? null
                    : () => _applySuggestedWorkerSetup({
                          'direct': chatgptWorker,
                          'research': geminiWorker,
                          'plan': geminiWorker,
                          'implement': chatgptWorker,
                          'test': chatgptWorker,
                          'verify': geminiWorker,
                        }),
                child: _savingWorkConfig
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Use recommended'),
              ),
            ],
          ),
        ),
      );

  Widget _singleWorkerSetupCard(StudioWorker worker) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Set up Work with ${_workerDisplayName(worker)} for every Step',
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: !_canConfigureWork || _savingWorkConfig
                    ? null
                    : () => _applySuggestedWorkerSetup({
                          for (final id in const [
                            'direct',
                            'research',
                            'plan',
                            'implement',
                            'test',
                            'verify',
                          ])
                            id: worker,
                        }),
                child: _savingWorkConfig
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text('Use ${_workerDisplayName(worker)} for all'),
              ),
            ],
          ),
        ),
      );

  Future<void> _applySuggestedWorkerSetup(
    Map<String, StudioWorker> assignments,
  ) async {
    final bindings = <String, dynamic>{
      for (final entry in assignments.entries)
        entry.key: {'workerId': entry.value.id},
    };
    await _saveWorkConfig({..._workConfig, 'bindings': bindings});
  }

  void _setStepBinding(String bindingId, Map<String, dynamic> binding) {
    final bindings = _workConfig['bindings'] is Map
        ? Map<String, dynamic>.from(_workConfig['bindings'] as Map)
        : <String, dynamic>{};
    final cleaned = Map<String, dynamic>.from(binding)
      ..removeWhere((key, value) => value == null || value == '');
    if (cleaned.isEmpty) {
      bindings.remove(bindingId);
    } else {
      bindings[bindingId] = cleaned;
    }
    setState(() => _workConfig = {..._workConfig, 'bindings': bindings});
  }

  String _workerDisplayName(StudioWorker worker) =>
      switch (worker.workerTypeId) {
        'chatgpt' => 'ChatGPT',
        'gemini' => 'Gemini',
        _ => worker.workerTypeId,
      };

  Future<void> _editStepBinding(
    String bindingId,
    Map<String, dynamic> current,
  ) async {
    final modelController =
        TextEditingController(text: current['model']?.toString() ?? '');
    final instructionsController = TextEditingController(
      text: current['additionalInstructions']?.toString() ?? '',
    );
    final eligibleWorkerIds =
        _eligibleWorkers.map((worker) => worker.id).toSet();
    var selectedWorker = current['workerId']?.toString() ?? '';
    if (!eligibleWorkerIds.contains(selectedWorker)) selectedWorker = '';
    var fallbackWorker = current['fallbackWorkerId']?.toString() ?? '';
    if (!eligibleWorkerIds.contains(fallbackWorker) ||
        fallbackWorker == selectedWorker) {
      fallbackWorker = '';
    }
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('${_stepDisplayName(bindingId)} settings'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: fallbackWorker,
                    decoration: const InputDecoration(
                        labelText: 'Fallback Worker (optional)'),
                    items: [
                      const DropdownMenuItem(
                          value: '', child: Text('No fallback')),
                      ..._eligibleWorkers
                          .where((worker) => worker.id != selectedWorker)
                          .map((worker) => DropdownMenuItem(
                                value: worker.id,
                                child: Text(
                                    '${_workerDisplayName(worker)} · ${_projectWorkspaceNames[worker.workspaceId] ?? worker.workspaceId}'),
                              )),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => fallbackWorker = value ?? ''),
                  ),
                  TextField(
                    controller: modelController,
                    decoration:
                        const InputDecoration(labelText: 'Model (optional)'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: instructionsController,
                    minLines: 2,
                    maxLines: 5,
                    maxLength: 4000,
                    decoration: const InputDecoration(
                      labelText: 'Step instructions (optional)',
                      helperText:
                          'Added to this Step. Conclave manages its built-in guidance.',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext, true);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == true && mounted) {
      final binding = <String, dynamic>{
        if (selectedWorker.isNotEmpty) 'workerId': selectedWorker,
        if (fallbackWorker.isNotEmpty) 'fallbackWorkerId': fallbackWorker,
      };
      final model = modelController.text.trim();
      final instructions = instructionsController.text.trim();
      if (model.isNotEmpty) binding['model'] = model;
      if (instructions.isNotEmpty) {
        binding['additionalInstructions'] = instructions;
      }
      _setStepBinding(bindingId, binding);
    }
    modelController.dispose();
    instructionsController.dispose();
  }

  Future<void> _saveWorkConfig(Map<String, dynamic> config) async {
    if (!_canConfigureWork) return;
    final ds = widget.dataSource;
    if (ds == null) return;
    setState(() => _savingWorkConfig = true);
    try {
      final updated = await ds.updateWorkstream(
        workstreamId: widget.workstream.id,
        workConfig: config,
      );
      if (!mounted) return;
      setState(() {
        _workConfig = Map<String, dynamic>.from(updated.workConfig);
        _workstreamInstructionsController.text =
            _workConfig['workstreamInstructions']?.toString() ?? '';
        _savingWorkConfig = false;
      });
      final defaultId = _workConfig['defaultWorkflowId']?.toString();
      final selectedDefault = _workflowCatalog
          .where((workflow) => workflow.id == defaultId)
          .map((workflow) => workflow.reference)
          .firstOrNull;
      if (selectedDefault != null) _workflow = selectedDefault;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Work settings saved')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _savingWorkConfig = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save Work settings: $error')),
      );
    }
  }

  Future<void> _runWork() async {
    final text = _requestController.text;
    final requestText = text.trim().isEmpty
        ? 'Please use the attached inputs to complete the request.'
        : text;
    final submit = widget.onRunWork;
    final dataSource = widget.dataSource;
    if (!_canExecute ||
        (text.trim().isEmpty && _workAttachments.isEmpty) ||
        submit == null ||
        _submittingWork) {
      return;
    }
    setState(() {
      _submittingWork = true;
      _workSubmitError = null;
    });
    try {
      final workflowId = _workflow.split(':').first;
      if (dataSource != null) {
        final issues = await dataSource.validateWorkRequestEligibility(
          workstreamId: widget.workstream.id,
          workflowId: workflowId,
          attachments: _workAttachments,
        );
        if (issues.isNotEmpty) {
          final workflowName = _workflowCatalog
                  .where((definition) => definition.id == workflowId)
                  .map((definition) => definition.name)
                  .firstOrNull ??
              workflowId;
          if (mounted) {
            setState(() => _workSubmitError =
                'Cannot run $workflowName\n${issues.map((issue) => '• $issue').join('\n')}');
          }
          return;
        }
      }
      final workRequestId =
          await submit(requestText, workflowId, _workAttachments);
      if (!mounted) return;
      _requestController.clear();
      setState(() {
        _workAttachments = [];
        _workTimeline = [
          ..._workTimeline,
          StudioWorkRequest(
            id: workRequestId,
            requestedByName: 'You',
            prompt: requestText,
            workflowId: workflowId,
            workflowVersion: 1,
            status: 'queued',
            createdAt: DateTime.now().toUtc().toIso8601String(),
            steps: const [],
          ),
        ];
      });
      if (dataSource != null) {
        await _refreshWorkTimeline();
      }
    } catch (error) {
      if (mounted) {
        final message = error is StudioApiException &&
                error.message.startsWith('Cannot run ')
            ? error.message
            : 'Could not run Work: $error';
        setState(() => _workSubmitError = message);
      }
    } finally {
      if (mounted) setState(() => _submittingWork = false);
    }
  }

  Future<void> _addWorkFiles() async {
    try {
      final selected = await work_request_files.pickWorkRequestFiles();
      final currentBytes = _workAttachments.fold<int>(
        0,
        (sum, item) => sum + (item['sizeBytes'] as int? ?? 0),
      );
      final selectedBytes = selected.fold<int>(
        0,
        (sum, item) => sum + (item['sizeBytes'] as int? ?? 0),
      );
      if (_workAttachments.length + selected.length > 10 ||
          currentBytes + selectedBytes > 1024 * 1024 ||
          selected
              .any((item) => (item['sizeBytes'] as int? ?? 0) > 1024 * 1024)) {
        throw const FormatException(
          'Choose up to 10 files, with each file and the total under 1 MB.',
        );
      }
      if (mounted && selected.isNotEmpty) {
        setState(() => _workAttachments = [..._workAttachments, ...selected]);
      }
    } on UnsupportedError catch (error) {
      if (mounted) setState(() => _workSubmitError = error.message.toString());
    } on FormatException catch (error) {
      if (mounted) setState(() => _workSubmitError = error.message.toString());
    }
  }

  Future<void> _addWorkReference() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a link'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://example.com'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add link'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty) return;
    if (_workAttachments.length >= 10) {
      if (mounted) {
        setState(() => _workSubmitError =
            'A Work Request can include up to 10 attachments.');
      }
      return;
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        value.length > 2048) {
      if (mounted) {
        setState(() => _workSubmitError =
            'Enter a valid http or https link (up to 2,048 characters).');
      }
      return;
    }
    if (mounted) {
      setState(() => _workAttachments = [
            ..._workAttachments,
            {
              'kind': 'url',
              'name': uri.host,
              'url': uri.toString(),
              'mediaType': 'text/uri-list',
              'sizeBytes': 0,
            },
          ]);
    }
  }

  Future<void> _refreshWorkTimeline({bool activeOnly = false}) async {
    final dataSource = widget.dataSource;
    if (dataSource == null) {
      if (_loadingWorkTimeline) {
        setState(() => _loadingWorkTimeline = false);
      }
      return;
    }
    if (_refreshingWorkTimeline) {
      _workTimelineRefreshPending = true;
      return;
    }
    _refreshingWorkTimeline = true;
    try {
      final requests = await dataSource.loadWorkstreamWorkRequests(
        workstreamId: widget.workstream.id,
        activeOnly: activeOnly,
      );
      if (!mounted) return;
      setState(() {
        if (activeOnly) {
          final updatedById = {
            for (final request in requests) request.id: request
          };
          _workTimeline = [
            for (final existing in _workTimeline)
              updatedById.remove(existing.id) ?? existing,
            ...updatedById.values,
          ]..sort((left, right) => left.createdAt.compareTo(right.createdAt));
        } else {
          _workTimeline = requests;
        }
        _loadingWorkTimeline = false;
        _workTimelineError = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loadingWorkTimeline = false;
          _workTimelineError = error.toString();
        });
      }
    } finally {
      _refreshingWorkTimeline = false;
      if (_workTimelineRefreshPending && mounted) {
        _workTimelineRefreshPending = false;
        unawaited(_refreshWorkTimeline(activeOnly: activeOnly));
      }
    }
  }

  Future<void> _showRunDetails(String workRequestId) async {
    final dataSource = widget.dataSource;
    if (dataSource == null) return;
    final details = dataSource.loadWorkRequest(workRequestId: workRequestId);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FutureBuilder<StudioWorkRequestStatus>(
        future: details,
        builder: (context, snapshot) {
          final height = MediaQuery.sizeOf(context).height * 0.88;
          if (snapshot.hasError) {
            return SizedBox(
              height: height,
              child: const Center(child: Text('Could not load Run details.')),
            );
          }
          if (!snapshot.hasData) {
            return SizedBox(
              height: height,
              child: const Center(child: CircularProgressIndicator()),
            );
          }
          return _WorkRequestDetailsSheet(
            details: snapshot.data!,
            onRetryStep: (step) => _retryWorkRequestStep(
              workRequestId,
              step,
              closeDetails: true,
            ),
            onCancelRun: () => _cancelFailedWorkRequest(
              workRequestId,
              closeDetails: true,
            ),
          );
        },
      ),
    );
  }

  Future<void> _retryWorkRequestStep(
      String workRequestId, StudioWorkRequestStep step,
      {bool closeDetails = false}) async {
    final dataSource = widget.dataSource;
    if (dataSource == null) return;
    String? sessionStrategy;
    if (step.kind == 'implement') {
      final resumeRecommended = const {
        'provider_unavailable',
        'authentication_required',
        'quota_exhausted',
        'worker_not_ready',
        'cli_not_found',
        'unsupported_cli_version',
        'model_not_supported',
        'permission_denied',
      }.contains(step.errorCode);
      final recommendation = resumeRecommended
          ? 'The failure looks like it happened before the Worker completed a turn. Resuming is recommended.'
          : 'The failure may have happened after work began. Starting fresh is recommended.';
      sessionStrategy = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Retry Implement'),
          content: Text(
            '$recommendation\n\nChoose how the retry should use provider context.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'resume'),
              child: Text(
                resumeRecommended
                    ? 'Resume previous session · Recommended'
                    : 'Resume previous session',
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, 'fresh'),
              child: Text(
                resumeRecommended ? 'Start fresh' : 'Start fresh · Recommended',
              ),
            ),
          ],
        ),
      );
      if (sessionStrategy == null) return;
    }
    try {
      await dataSource.retryWorkRequestStep(
        workRequestId: workRequestId,
        stepKind: step.kind,
        sessionStrategy: sessionStrategy,
      );
      if (!mounted) return;
      if (closeDetails) Navigator.of(context).pop();
      unawaited(_refreshWorkTimeline());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Retrying ${step.kind} Step.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not retry this Step. Check Worker readiness.'),
        ),
      );
    }
  }

  Future<void> _cancelFailedWorkRequest(
    String workRequestId, {
    bool closeDetails = false,
  }) async {
    final dataSource = widget.dataSource;
    if (dataSource == null) return;
    try {
      await dataSource.cancelWorkRequest(workRequestId: workRequestId);
      if (!mounted) return;
      if (closeDetails) Navigator.of(context).pop();
      unawaited(_refreshWorkTimeline());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Run cancelled.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not cancel this Run.')),
      );
    }
  }

  Future<void> _sendDiscussion() async {
    final text = _discussionController.text.trim();
    if (text.isEmpty) return;
    _discussionController.clear();
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final tempId = 'temp-${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _discussion.add(
        _DiscussionItem(
          id: tempId,
          author: 'You',
          text: text,
          sentAt: '$hour:$minute',
          isMe: true,
        ),
      );
    });

    final ds = widget.dataSource;
    if (ds != null) {
      try {
        final saved = await ds.sendDiscussionMessage(
          workstreamId: widget.workstream.id,
          text: text,
        );
        if (!mounted) return;
        setState(() {
          final idx = _discussion.indexWhere((item) => item.id == tempId);
          if (idx != -1) {
            final dt = DateTime.tryParse(saved.createdAt)?.toLocal();
            final timeStr = dt != null
                ? '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}'
                : '$hour:$minute';
            _discussion[idx] = _DiscussionItem(
              id: saved.id,
              author: 'You',
              text: saved.body,
              sentAt: timeStr,
              isMe: true,
            );
          }
        });
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save message: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _editDiscussion(String messageId, String newText) async {
    setState(() {
      final idx = _discussion.indexWhere((m) => m.id == messageId);
      if (idx != -1) {
        final old = _discussion[idx];
        _discussion[idx] = _DiscussionItem(
          id: old.id,
          author: old.author,
          text: newText,
          sentAt: old.sentAt,
          isMe: old.isMe,
        );
      }
    });

    final ds = widget.dataSource;
    if (ds != null && !messageId.startsWith('temp-')) {
      try {
        await ds.editDiscussionMessage(
          messageId: messageId,
          text: newText,
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update message: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }
}

Widget _workflowOption(
  BuildContext context,
  StudioBuiltinWorkflow workflow,
) =>
    ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: SizedBox(
        height: 54,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: workflow.name),
                const TextSpan(text: '  —  '),
                TextSpan(
                  text: workflow.description,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );

class _WorkComposer extends StatelessWidget {
  const _WorkComposer({
    required this.requestController,
    required this.workflow,
    required this.workflowCatalog,
    required this.loadingWorkflows,
    required this.workflowCatalogError,
    required this.canExecute,
    required this.workTimeline,
    required this.loadingTimeline,
    required this.timelineError,
    required this.submitError,
    required this.submitting,
    required this.attachments,
    required this.onAddFiles,
    required this.onAddReference,
    required this.onRemoveAttachment,
    required this.onRefresh,
    required this.onShowRunDetails,
    required this.onRetryStep,
    required this.onCancelRun,
    required this.onWorkflowChanged,
    required this.onRun,
  });

  final TextEditingController requestController;
  final String workflow;
  final List<StudioBuiltinWorkflow> workflowCatalog;
  final bool loadingWorkflows;
  final String? workflowCatalogError;
  final bool canExecute;
  final List<StudioWorkRequest> workTimeline;
  final bool loadingTimeline;
  final String? timelineError;
  final String? submitError;
  final bool submitting;
  final List<Map<String, dynamic>> attachments;
  final Future<void> Function() onAddFiles;
  final Future<void> Function() onAddReference;
  final ValueChanged<int> onRemoveAttachment;
  final Future<void> Function() onRefresh;
  final ValueChanged<String>? onShowRunDetails;
  final Future<void> Function(String, StudioWorkRequestStep)? onRetryStep;
  final Future<void> Function(String)? onCancelRun;
  final ValueChanged<String> onWorkflowChanged;
  final Future<void> Function() onRun;

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
            enabled: canExecute && !submitting,
            decoration: const InputDecoration(
              labelText: 'What should Conclave do?',
              hintText:
                  'Example: Investigate the login failure and propose a fix.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                onPressed: canExecute && !submitting ? onAddFiles : null,
                icon: const Icon(Icons.attach_file),
                label: const Text('Add files'),
              ),
              OutlinedButton.icon(
                onPressed: canExecute && !submitting ? onAddReference : null,
                icon: const Icon(Icons.link),
                label: const Text('Add link'),
              ),
              for (var i = 0; i < attachments.length; i++)
                InputChip(
                  avatar: Icon(attachments[i]['kind'] == 'url'
                      ? Icons.link
                      : Icons.insert_drive_file),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      (attachments[i]['name'] ?? 'Attachment').toString(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  onDeleted: canExecute && !submitting
                      ? () => onRemoveAttachment(i)
                      : null,
                ),
            ],
          ),
          if (attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Up to 10 attachments. Files total 1 MB; links are passed as references.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 12),
          if (loadingWorkflows)
            const LinearProgressIndicator()
          else if (workflowCatalogError != null)
            Text(workflowCatalogError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error))
          else ...[
            DropdownButtonFormField<String>(
              isExpanded: true,
              itemHeight: null,
              initialValue: workflow,
              decoration: const InputDecoration(labelText: 'Workflow'),
              selectedItemBuilder: (context) => workflowCatalog
                  .map((definition) => Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          definition.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ))
                  .toList(),
              items: workflowCatalog
                  .map((definition) => DropdownMenuItem(
                        value: definition.reference,
                        child: _workflowOption(context, definition),
                      ))
                  .toList(),
              onChanged: canExecute
                  ? (value) {
                      if (value != null) onWorkflowChanged(value);
                    }
                  : null,
            ),
            const SizedBox(height: 4),
            Text(
              workflowCatalog
                      .where((definition) => definition.reference == workflow)
                      .map((definition) =>
                          '${definition.description}\n${definition.steps.map((step) => step.kind).join(' → ')}')
                      .firstOrNull ??
                  '',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: canExecute &&
                    !submitting &&
                    !loadingWorkflows &&
                    workflowCatalogError == null
                ? () => onRun()
                : null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Run'),
          ),
          if (!canExecute)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                  'Viewer access can read the workstream but cannot run Work.'),
            ),
          if (submitting) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
            const SizedBox(height: 6),
            const Text('Checking Worker setup and starting Work…'),
          ],
          if (submitError != null) ...[
            const SizedBox(height: 10),
            Text(submitError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: Text('Work history',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              IconButton(
                tooltip: 'Refresh Work history',
                onPressed: () => onRefresh(),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (loadingTimeline && workTimeline.isEmpty)
            const LinearProgressIndicator()
          else if (timelineError != null && workTimeline.isEmpty)
            Text('Could not load Work history: $timelineError',
                style: TextStyle(color: Theme.of(context).colorScheme.error))
          else if (workTimeline.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Submitted Work requests will appear here.'),
            )
          else ...[
            const SizedBox(height: 20),
            ...workTimeline.map((request) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _WorkTimelineCard(
                    request: request,
                    workflowCatalog: workflowCatalog,
                    onShowRunDetails: onShowRunDetails,
                    onRetryStep: onRetryStep,
                    onCancelRun: onCancelRun,
                  ),
                )),
          ],
        ]),
      );
}

class _WorkTimelineCard extends StatelessWidget {
  const _WorkTimelineCard({
    required this.request,
    required this.workflowCatalog,
    required this.onShowRunDetails,
    required this.onRetryStep,
    required this.onCancelRun,
  });

  final StudioWorkRequest request;
  final List<StudioBuiltinWorkflow> workflowCatalog;
  final ValueChanged<String>? onShowRunDetails;
  final Future<void> Function(String, StudioWorkRequestStep)? onRetryStep;
  final Future<void> Function(String)? onCancelRun;

  String get _workflowName =>
      workflowCatalog
          .where((workflow) =>
              workflow.id == request.workflowId &&
              workflow.version == request.workflowVersion)
          .map((workflow) => workflow.name)
          .firstOrNull ??
      request.workflowId;

  String _stepName(String kind) => switch (kind) {
        'implement' => 'Implement',
        'research' => 'Research',
        'plan' => 'Plan',
        'test' => 'Test',
        'verify' => 'Verify',
        _ => kind,
      };

  String _elapsed(int? milliseconds) {
    if (milliseconds == null) return '';
    final seconds = milliseconds ~/ 1000;
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return minutes > 0 ? '${minutes}m ${remainder}s' : '${remainder}s';
  }

  IconData _statusIcon(String status) => switch (status) {
        'completed' => Icons.check_circle,
        'running' => Icons.circle,
        'failed' => Icons.error,
        'cancelled' => Icons.cancel,
        _ => Icons.circle_outlined,
      };

  String _stepStatusLabel(String status) => switch (status) {
        'completed' => 'done',
        'running' => 'running',
        'failed' => 'failed',
        'cancelled' => 'cancelled',
        _ => 'waiting',
      };

  String _workerName(StudioWorkRequestStep step) => switch (step.workerTypeId) {
        'chatgpt' => 'ChatGPT',
        'gemini' => 'Gemini',
        _ => step.providerToolName ??
            step.workerTypeId?.split('.').last ??
            (step.workerId == null ? 'Worker pending' : 'Configured Worker'),
      };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final timestamp = DateTime.tryParse(request.createdAt)?.toLocal();
    final timeLabel = timestamp == null
        ? ''
        : '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')} '
            '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
    final cancelledSteps =
        request.steps.where((step) => step.status == 'cancelled').toList();
    final overall = request.status == 'cancelled'
        ? 'Cancelled${cancelledSteps.isEmpty ? '' : ' during ${_stepName(cancelledSteps.first.kind)}'}'
        : request.status[0].toUpperCase() + request.status.substring(1);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(request.requestedByName,
                    style: Theme.of(context).textTheme.titleSmall),
              ),
              Text(timeLabel, style: Theme.of(context).textTheme.bodySmall),
            ]),
            const SizedBox(height: 8),
            SelectableText(request.prompt),
            const SizedBox(height: 14),
            Text('$_workflowName · $overall',
                style: Theme.of(context).textTheme.titleSmall),
            if (request.steps.isEmpty &&
                (request.status == 'queued' ||
                    request.status == 'running')) ...[
              const SizedBox(height: 8),
              const Text('Preparing Worker assignment…'),
            ],
            if (request.steps.isNotEmpty) ...[
              const SizedBox(height: 8),
              ...request.steps.map((step) {
                final worker = _workerName(step);
                final details = [
                  worker,
                  if (step.engineVersion != null)
                    'Engine ${step.engineVersion}',
                  if (step.providerToolVersion != null)
                    step.providerToolVersion!,
                  if (_elapsed(step.elapsedMs).isNotEmpty)
                    _elapsed(step.elapsedMs),
                ].join(' · ');
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(_statusIcon(step.status),
                            size: 17,
                            color: step.status == 'failed'
                                ? colors.error
                                : step.status == 'completed'
                                    ? colors.primary
                                    : colors.secondary),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_stepName(step.kind))),
                        Text(_stepStatusLabel(step.status)),
                      ]),
                      if (step.status == 'running' ||
                          step.status == 'completed' ||
                          step.status == 'failed')
                        Padding(
                          padding: const EdgeInsets.only(left: 25, top: 2),
                          child: Text(details,
                              style: Theme.of(context).textTheme.bodySmall),
                        ),
                      if (step.status == 'failed') ...[
                        Padding(
                          padding: const EdgeInsets.only(left: 25, top: 6),
                          child: Text(
                            step.errorMessage ??
                                'This Step could not be completed.',
                            style: TextStyle(color: colors.error),
                          ),
                        ),
                        if (request.status == 'failed' && onRetryStep != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 16),
                            child: TextButton.icon(
                              onPressed: () => onRetryStep!(request.id, step),
                              icon: const Icon(Icons.refresh),
                              label: const Text('Retry step'),
                            ),
                          ),
                      ],
                    ],
                  ),
                );
              }),
            ],
            if (request.testSummary != null) ...[
              const SizedBox(height: 8),
              Text('Tests · ${request.testSummary}',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            if (request.finalText != null && request.finalText!.isNotEmpty) ...[
              const Divider(height: 24),
              Text('Conclave · $overall · $_workflowName',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              SelectableText(request.finalText!),
            ] else if (request.status == 'failed' && request.error != null) ...[
              const Divider(height: 24),
              Text('Conclave · Failed',
                  style: TextStyle(
                      color: colors.error, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              SelectableText(request.error!),
            ],
            if ((request.status == 'queued' ||
                    request.status == 'running' ||
                    request.status == 'failed') &&
                onCancelRun != null) ...[
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: () => onCancelRun!(request.id),
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Cancel run'),
              ),
            ],
            if (onShowRunDetails != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => onShowRunDetails!(request.id),
                icon: const Icon(Icons.subject),
                label: const Text('Run details'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WorkRequestDetailsSheet extends StatelessWidget {
  const _WorkRequestDetailsSheet({
    required this.details,
    required this.onRetryStep,
    required this.onCancelRun,
  });

  final StudioWorkRequestStatus details;
  final Future<void> Function(StudioWorkRequestStep step) onRetryStep;
  final Future<void> Function() onCancelRun;

  String _stepName(String kind) => switch (kind) {
        'research' => 'Research',
        'plan' => 'Plan',
        'implement' => 'Implement',
        'test' => 'Test',
        'verify' => 'Verify',
        _ => kind,
      };

  String _workerName(StudioWorkRequestStep step) => switch (step.workerTypeId) {
        'chatgpt' => 'ChatGPT',
        'gemini' => 'Gemini',
        _ => step.providerToolName ?? step.workerTypeId ?? 'Worker',
      };

  String _timestamp(String? value) {
    if (value == null) return '—';
    final parsed = DateTime.tryParse(value)?.toLocal();
    if (parsed == null) return '—';
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')} '
        '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}:${parsed.second.toString().padLeft(2, '0')}';
  }

  String _duration(int? milliseconds) {
    if (milliseconds == null) return '—';
    final seconds = milliseconds ~/ 1000;
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return minutes > 0 ? '${minutes}m ${remainder}s' : '${remainder}s';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final workflow = details.workflowName ?? details.workflowId ?? 'Workflow';
    final version = details.workflowVersion;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.88,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text('Run details',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                Text(
                  '$workflow${version == null ? '' : ' · v$version'} · ${details.status}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (details.requestedByName?.isNotEmpty == true) ...[
                  const SizedBox(height: 6),
                  Text('Requested by ${details.requestedByName}'),
                ],
                const SizedBox(height: 16),
                Text('Original request',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                SelectableText(details.originalRequest?.isNotEmpty == true
                    ? details.originalRequest!
                    : 'No request text was recorded.'),
                const SizedBox(height: 20),
                for (final step in details.steps) ...[
                  Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(_stepName(step.kind),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                              ),
                              Text(step.status),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            [
                              _workerName(step),
                              if (step.engineVersion != null)
                                'Engine ${step.engineVersion}',
                              if (step.providerToolName != null &&
                                  step.providerToolVersion != null)
                                '${step.providerToolName} ${step.providerToolVersion}',
                              if (step.providerToolName != null &&
                                  step.providerToolVersion == null)
                                step.providerToolName!,
                            ].join(' · '),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 18,
                            runSpacing: 6,
                            children: [
                              Text('Started · ${_timestamp(step.startedAt)}'),
                              Text('Ended · ${_timestamp(step.completedAt)}'),
                              Text('Duration · ${_duration(step.elapsedMs)}'),
                            ],
                          ),
                          if (step.resultText?.isNotEmpty == true) ...[
                            const Divider(height: 24),
                            Text('Result',
                                style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 6),
                            SelectableText(step.resultText!),
                          ] else if (step.status == 'failed') ...[
                            const Divider(height: 24),
                            Text(
                              step.errorMessage ??
                                  'This Step did not produce a result.',
                              style: TextStyle(color: colors.error),
                            ),
                            if (details.status == 'failed') ...[
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                onPressed: () => onRetryStep(step),
                                icon: const Icon(Icons.refresh),
                                label: const Text('Retry step'),
                              ),
                            ],
                          ],
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            childrenPadding: EdgeInsets.zero,
                            title: const Text('Advanced technical details'),
                            children: [
                              if (step.assignmentId != null)
                                _detailValue(
                                    'Assignment ID', step.assignmentId!),
                              if (step.engineVersion != null)
                                _detailValue(
                                    'Engine version', step.engineVersion!),
                              if (step.profileDefinitionId != null)
                                _detailValue(
                                  'Tool Profile',
                                  '${step.profileDefinitionId}'
                                      '${step.profileReleaseVersion == null ? '' : '@${step.profileReleaseVersion}'}',
                                ),
                              if (step.providerToolVersion != null)
                                _detailValue(
                                    '${step.providerToolName ?? 'Provider tool'} version',
                                    step.providerToolVersion!),
                              if (step.model != null)
                                _detailValue('Model', step.model!),
                              if (step.sessionPolicy != null)
                                _detailValue(
                                  'Session mode',
                                  step.sessionPolicy == 'durable_session'
                                      ? 'Durable session'
                                      : 'Stateless',
                                ),
                              if (step.retrySessionStrategy != null)
                                _detailValue(
                                  'Last retry session',
                                  step.retrySessionStrategy == 'fresh'
                                      ? 'Started fresh'
                                      : 'Resumed previous session',
                                ),
                              if (step.errorCode != null)
                                _detailValue(
                                    'Stable error code', step.errorCode!),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (details.errorCode != null &&
                    details.steps.every((step) => step.errorCode == null))
                  Text('Run error code: ${details.errorCode}'),
                if (details.status == 'failed' ||
                    details.status == 'queued' ||
                    details.status == 'running') ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: onCancelRun,
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Cancel run'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailValue(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 180, child: Text(label)),
            Expanded(child: SelectableText(value)),
          ],
        ),
      );
}

class _DiscussionItem {
  const _DiscussionItem({
    required this.id,
    required this.author,
    required this.text,
    this.sentAt,
    this.isMe = true,
  });

  final String id;
  final String author;
  final String text;
  final String? sentAt;
  final bool isMe;
}

class _DiscussionMessageBubble extends StatefulWidget {
  const _DiscussionMessageBubble({
    super.key,
    required this.item,
    required this.onCopy,
    required this.onEdit,
  });

  final _DiscussionItem item;
  final VoidCallback onCopy;
  final ValueChanged<String> onEdit;

  @override
  State<_DiscussionMessageBubble> createState() =>
      _DiscussionMessageBubbleState();
}

class _DiscussionMessageBubbleState extends State<_DiscussionMessageBubble> {
  bool _isEditing = false;
  late TextEditingController _editController;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController(text: widget.item.text);
  }

  @override
  void didUpdateWidget(covariant _DiscussionMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.text != widget.item.text && !_isEditing) {
      _editController.text = widget.item.text;
    }
  }

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  void _saveEdit() {
    final text = _editController.text.trim();
    if (text.isNotEmpty) {
      widget.onEdit(text);
    }
    setState(() => _isEditing = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMe = widget.item.isMe;

    final initials = widget.item.author.isNotEmpty
        ? widget.item.author
            .trim()
            .split(' ')
            .where((s) => s.isNotEmpty)
            .map((s) => s[0])
            .take(2)
            .join()
            .toUpperCase()
        : 'U';

    final textColor = isDark ? Colors.white : const Color(0xff1f1d2b);
    final metaColor = isDark ? Colors.white38 : Colors.black45;
    final borderColor =
        isDark ? const Color(0xff2d2b42) : const Color(0xffe2e0ed);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: borderColor,
              width: 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isMe) ...[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 11,
                      backgroundColor: isDark
                          ? const Color(0xff3f3b61)
                          : const Color(0xffd8d2ff),
                      child: Text(
                        initials,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color:
                              isDark ? Colors.white70 : const Color(0xff4238a0),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      widget.item.author,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
              if (_isEditing) ...[
                TextField(
                  controller: _editController,
                  minLines: 1,
                  maxLines: 6,
                  autofocus: true,
                  style: TextStyle(fontSize: 13.5, color: textColor),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 4),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => setState(() {
                        _editController.text = widget.item.text;
                        _isEditing = false;
                      }),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _saveEdit,
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ] else ...[
                SelectableText(
                  widget.item.text,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.45,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.item.sentAt != null) ...[
                      Text(
                        widget.item.sentAt!,
                        style: TextStyle(
                          fontSize: 11,
                          color: metaColor,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Tooltip(
                      message: 'Copy message',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: widget.onCopy,
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            Icons.copy_rounded,
                            size: 14,
                            color: metaColor,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'Edit message',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => setState(() {
                          _editController.text = widget.item.text;
                          _isEditing = true;
                        }),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            Icons.edit_outlined,
                            size: 14,
                            color: metaColor,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DiscussionInputBox extends StatelessWidget {
  const _DiscussionInputBox({
    required this.controller,
    required this.onSend,
  });

  final TextEditingController controller;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.enter) {
          if (HardwareKeyboard.instance.isShiftPressed) {
            return KeyEventResult.ignored;
          } else {
            onSend();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: TextField(
        controller: controller,
        minLines: 1,
        maxLines: 8,
        keyboardType: TextInputType.multiline,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
              color: isDark ? const Color(0xff2d2b42) : const Color(0xffe5e3f0),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
              color: isDark ? const Color(0xff2d2b42) : const Color(0xffe5e3f0),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(
              color: Color(0xff7c3aed),
              width: 1.5,
            ),
          ),
          isDense: true,
          contentPadding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          suffixIcon: IconButton(
            onPressed: onSend,
            icon: const Icon(Icons.send_rounded, size: 18),
            tooltip: 'Send message',
            color: const Color(0xff7c3aed),
          ),
        ),
      ),
    );
  }
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
