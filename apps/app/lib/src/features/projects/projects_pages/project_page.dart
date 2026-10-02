part of '../projects_pages.dart';

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

  final AxProject project;
  final AxDataSource dataSource;
  final ValueChanged<String> onOpenWorkstream;
  final ValueChanged<String>? onOpenWorkspace;
  final VoidCallback? onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final ValueChanged<AxProject>? onProjectUpdated;

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

  final AxProject project;
  final AxDataSource dataSource;
  final ValueChanged<String> onOpenWorkstream;
  final ValueChanged<String>? onOpenWorkspace;
  final VoidCallback? onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final ValueChanged<AxProject>? onProjectUpdated;

  @override
  State<_ProjectWorkspace> createState() => _ProjectWorkspaceState();
}

class _ProjectWorkspaceState extends State<_ProjectWorkspace>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late List<AxWorkstream> workstreams;
  List<AxProjectMember> members = const [];
  List<AxProjectInvitation> invitations = const [];
  List<AxAuditEntry> audit = const [];
  List<AxWorkspace> ownedWorkspaces = const [];
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
        ownedWorkspaces = loaded[0] as List<AxWorkspace>;
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

  Future<void> _editWorkstream(AxWorkstream workstream) async {
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

  Future<void> _deleteWorkstream(AxWorkstream workstream) async {
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
    AxWorkstream workstream,
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
    final previousList = List<AxWorkstream>.from(workstreams);
    final updatedList = List<AxWorkstream>.from(workstreams);
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
        settings: {
          ...widget.project.settings,
          'workstreamOrder': orderIds,
        },
      );
      if (!mounted) return;
      final mergedProject = AxProject(
        id: updatedProject.id,
        name: updatedProject.name,
        branch: updatedProject.branch,
        lastActivity: updatedProject.lastActivity,
        workstreams: updatedList,
        description: updatedProject.description,
        instructions: updatedProject.instructions,
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
      final fetchedWorkstreams = loaded[3] as List<AxWorkstream>;
      setState(() {
        members = loaded[0] as List<AxProjectMember>;
        invitations = loaded[1] as List<AxProjectInvitation>;
        audit = loaded[2] as List<AxAuditEntry>;
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

  Future<void> _changeRole(AxProjectMember member) async {
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

  Future<void> _removeMember(AxProjectMember member) async {
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

  Future<void> _revokeInvitation(AxProjectInvitation invite) async {
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

  Widget _workstreamListTile(AxWorkstream workstream, int index) {
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
