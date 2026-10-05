part of '../projects_pages.dart';

extension _ProjectWorkspaceActions on _ProjectWorkspaceState {
  Future<void> _saveField(String field) async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _message('Project name cannot be empty.');
      return;
    }
    _updateState(() => _savingField = true);
    try {
      final updated = await widget.dataSource.updateProject(
        projectId: widget.project.id,
        name: name,
        description: _descriptionController.text.trim(),
        instructions: _instructionsController.text.trim(),
        settings: widget.project.settings,
      );
      if (!mounted) return;
      _updateState(() {
        _editingField = null;
        _savingField = false;
      });
      _message('Project updated.');
      widget.onProjectUpdated?.call(updated);
    } catch (error) {
      if (mounted) {
        _updateState(() => _savingField = false);
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
      _updateState(() {
        ownedWorkspaces = loaded[0] as List<AxWorkspace>;
        projectWorkspaces = loaded[1] as List<Map<String, dynamic>>;
        executionLoading = false;
      });
    } catch (_) {
      if (mounted) _updateState(() => executionLoading = false);
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
    final permissions = await _chooseWorkspaceAccess(const []);
    if (permissions == null) return;
    try {
      await widget.dataSource.requestProjectWorkspace(
        projectId: widget.project.id,
        workspaceId: selectedId,
        allowedPermissions: permissions,
      );
      await _loadExecution();
      _message('Workspace connected to this Project.');
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<List<String>?> _chooseWorkspaceAccess(List<String> current) async {
    final selected = current.toSet();
    return showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
                title: const Text('Workspace access'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text(
                      'Choose what Workers may do in this Project. Direct needs repository read and write access. Test steps also need command execution.'),
                  for (final entry in const {
                    'repository:read': 'Read repository files',
                    'repository:write': 'Change repository files',
                    'shell:execute': 'Execute commands and tests',
                  }.entries)
                    CheckboxListTile(
                      title: Text(entry.value),
                      value: selected.contains(entry.key),
                      onChanged: (value) => update(() {
                        if (value == true) {
                          selected.add(entry.key);
                        } else {
                          selected.remove(entry.key);
                        }
                      }),
                    ),
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(dialogContext, selected.toList()),
                      child: const Text('Confirm access')),
                ],
              )),
    );
  }

  Future<void> _editWorkspaceAccess(Map<String, dynamic> workspace) async {
    final permissions = await _chooseWorkspaceAccess(
        (workspace['allowedPermissions'] as List? ?? const [])
            .whereType<String>()
            .toList());
    if (permissions == null) return;
    try {
      await widget.dataSource.updateWorkspaceProjectPermissions(
        grantId: (workspace['id'] ?? workspace['grantId']).toString(),
        allowedPermissions: permissions,
      );
      await _loadExecution();
      if (mounted) {
        _message('Workspace access updated. Return to the chat and run again.');
      }
    } catch (error) {
      if (mounted) _message(error.toString());
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
      _updateState(() => workstreams = [...workstreams, workstream]);
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
      _updateState(() {
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
      _updateState(() {
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
      _updateState(() {
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
    _updateState(() {
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
        _updateState(() {
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
      _updateState(() {
        members = loaded[0] as List<AxProjectMember>;
        invitations = loaded[1] as List<AxProjectInvitation>;
        audit = loaded[2] as List<AxAuditEntry>;
        workstreams = fetchedWorkstreams.isNotEmpty
            ? fetchedWorkstreams
            : widget.project.workstreams;
        loading = false;
      });
    } catch (_) {
      if (mounted) _updateState(() => loading = false);
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
                      _updateState(() {
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
                _updateState(() {
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
}
