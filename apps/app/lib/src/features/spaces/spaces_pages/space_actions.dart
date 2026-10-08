part of '../spaces_pages.dart';

extension _SpaceWorkspaceActions on _SpaceWorkspaceState {
  Future<void> _editSpaceDialog() async {
    var name = widget.space.name;
    var description = widget.space.description;
    var instructions = widget.space.instructions;
    String? errorText;

    final result = await showDialog<(String, String, String)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            final trimmedName = name.trim();
            if (trimmedName.isEmpty) {
              setDialogState(() {
                errorText = 'Space name cannot be empty.';
              });
              return;
            }
            Navigator.pop(
              dialogContext,
              (trimmedName, description.trim(), instructions.trim()),
            );
          }

          return AlertDialog(
            title: const Text('Edit Space'),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      initialValue: name,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: 'Space Name',
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
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: description,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                      ),
                      maxLines: 2,
                      onChanged: (value) => description = value,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: instructions,
                      decoration: const InputDecoration(
                        labelText: 'Instructions',
                      ),
                      maxLines: 4,
                      onChanged: (value) => instructions = value,
                    ),
                  ],
                ),
              ),
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

    if (result == null) return;
    try {
      final updated = await _collaboration.editSpace(
        widget.space,
        name: result.$1,
        description: result.$2,
        instructions: result.$3,
        settings: widget.space.settings,
      );
      if (!mounted) return;
      _message('Space updated.');
      widget.onSpaceUpdated?.call(updated);
    } catch (error) {
      if (mounted) {
        _message(error.toString());
      }
    }
  }

  Future<void> _connectWorkspace() async {
    try {
      final values = await _queries.engine.ensure(_queries.ownedWorkspaces);
      if (!mounted) return;
      ownedWorkspaces = values;
    } catch (error) {
      if (mounted) _message(error.toString());
      return;
    }
    if (ownedWorkspaces.isEmpty) {
      _message(
          'Connect a Workspace first. You can grant it access to this Space later.');
      return;
    }
    var selectedId = ownedWorkspaces.first.id;
    String? errorText;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            final alreadyConnected = spaceWorkspaces.any((pw) {
              final pwId = (pw['workspaceId'] ?? pw['id'] ?? '').toString();
              return pwId == selectedId;
            });
            if (alreadyConnected) {
              setDialogState(() {
                errorText =
                    'This Workspace is already connected to this Space.';
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
      await _grants.create(
        spaceId: widget.space.id,
        workspaceId: selectedId,
        workspaceName: ownedWorkspaces
            .where((workspace) => workspace.id == selectedId)
            .first
            .name,
        allowedPermissions: permissions,
      );
      _message('Workspace connected to this Space.');
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
                      'Choose what Workers may do in this Space. Work needs repository read and write access. Test steps also need command execution.'),
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
      await _grants.updatePermissions(
        spaceId: widget.space.id,
        grantId: (workspace['id'] ?? workspace['grantId']).toString(),
        allowedPermissions: permissions,
      );
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
            'Disconnecting this Workspace will revoke execution capacity for this Space.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style:
                FilledButton.styleFrom(backgroundColor: ConclaveColors.error),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      if (grantId.isNotEmpty) {
        await _grants.revoke(spaceId: widget.space.id, grantId: grantId);
      }
      _message('Workspace grant revoked.');
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _createThread() async {
    var name = '';
    String? errorText;
    final created = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            final trimmed = name.trim();
            if (trimmed.isEmpty) return;
            final exists = threads.any(
              (w) => w.name.trim().toLowerCase() == trimmed.toLowerCase(),
            );
            if (exists) {
              setDialogState(() {
                errorText = 'A thread with this name already exists.';
              });
              return;
            }
            Navigator.pop(dialogContext, trimmed);
          }

          return AlertDialog(
            title: const Text('Create Thread'),
            content: TextField(
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Thread name',
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
                child: const Text('Create Thread'),
              ),
            ],
          );
        },
      ),
    );
    if (created == null || created.isEmpty) return;
    try {
      final thread = await _collaboration.createThread(
        spaceId: widget.space.id,
        name: created,
      );
      if (!mounted) return;

      widget.onSpaceUpdated?.call(widget.space);
      widget.onOpenThread(thread.id);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _editThread(AxThread thread) async {
    var name = thread.name;
    String? errorText;
    final updatedName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          void submit() {
            final trimmed = name.trim();
            if (trimmed.isEmpty) return;
            final exists = threads.any(
              (w) =>
                  w.id != thread.id &&
                  w.name.trim().toLowerCase() == trimmed.toLowerCase(),
            );
            if (exists) {
              setDialogState(() {
                errorText = 'A thread with this name already exists.';
              });
              return;
            }
            Navigator.pop(dialogContext, trimmed);
          }

          return AlertDialog(
            title: const Text('Edit Thread'),
            content: TextFormField(
              initialValue: thread.name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Thread name',
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
        updatedName == thread.name) {
      return;
    }
    try {
      await _collaboration.editThread(
        thread,
        name: updatedName,
      );
      if (!mounted) return;

      _message('Thread updated.');
      widget.onSpaceUpdated?.call(widget.space);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _deleteThread(AxThread thread) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete "${thread.name}"?'),
        content: const Text(
            'Are you sure you want to delete this Thread? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style:
                FilledButton.styleFrom(backgroundColor: ConclaveColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _collaboration.deleteThread(thread);
      if (!mounted) return;

      _message('Thread deleted.');
      widget.onSpaceUpdated?.call(widget.space);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _setThreadArchived(
    AxThread thread,
    bool archived,
  ) async {
    try {
      await _collaboration.editThread(
        thread,
        status: archived ? 'archived' : 'active',
      );
      if (!mounted) return;

      _message(archived ? 'Thread archived.' : 'Thread restored.');
      widget.onSpaceUpdated?.call(widget.space);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _moveThread(int index, int delta) async {
    final targetIndex = index + delta;
    if (targetIndex < 0 || targetIndex >= threads.length) return;
    final previousList = List<AxThread>.from(threads);
    final updatedList = List<AxThread>.from(threads);
    final item = updatedList.removeAt(index);
    updatedList.insert(targetIndex, item);
    _updateState(() {
      threads = updatedList;
    });
    try {
      final orderIds = updatedList.map((w) => w.id).toList();
      final updatedSpace = await _collaboration.editSpace(
        widget.space,
        name: widget.space.name,
        description: widget.space.description,
        instructions: widget.space.instructions,
        settings: {
          ...widget.space.settings,
          'threadOrder': orderIds,
        },
      );
      if (!mounted) return;
      final mergedSpace = AxSpace(
        id: updatedSpace.id,
        name: updatedSpace.name,
        branch: updatedSpace.branch,
        lastActivity: updatedSpace.lastActivity,
        threads: updatedList,
        description: updatedSpace.description,
        instructions: updatedSpace.instructions,
        archived: updatedSpace.archived,
        role: updatedSpace.role.isNotEmpty
            ? updatedSpace.role
            : widget.space.role,
        settings: updatedSpace.settings,
      );
      _recordThreads();
      widget.onSpaceUpdated?.call(mergedSpace);
    } catch (error) {
      if (mounted) {
        _updateState(() {
          threads = previousList;
        });
        _message(error.toString());
      }
    }
  }

  void _message(String message) {
    if (!mounted) return;
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
            textColor: ConclaveColors.primaryForegroundDark,
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
                errorText = 'This user is already a member of the Space.';
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
            title: const Text('Share Space'),
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
      await widget.dataSource.inviteSpaceMember(
          spaceId: widget.space.id, email: result.$1, role: result.$2);
      _message('Space invitation sent.');
      await _queries.refreshMembers(widget.space.id, includeMembers: false);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _changeRole(AxSpaceMember member) async {
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
    await widget.dataSource.changeSpaceMemberRole(
        spaceId: widget.space.id, userId: member.userId, role: role);
    await _queries.refreshMembers(widget.space.id, includeInvitations: false);
  }

  Future<void> _removeMember(AxSpaceMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove "${member.displayName}"?'),
        content: const Text(
            'Are you sure you want to remove this member from the Space?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style:
                FilledButton.styleFrom(backgroundColor: ConclaveColors.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.dataSource
        .removeSpaceMember(spaceId: widget.space.id, userId: member.userId);
    _message('${member.displayName} was removed from the Space.');
    await _queries.refreshMembers(widget.space.id, includeInvitations: false);
  }

  Future<void> _revokeInvitation(AxSpaceInvitation invite) async {
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
            style:
                FilledButton.styleFrom(backgroundColor: ConclaveColors.error),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.dataSource.expireSpaceInvitation(
        spaceId: widget.space.id,
        invitationId: invite.id,
      );
      _message('Invitation revoked.');
      await _queries.refreshMembers(widget.space.id, includeMembers: false);
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _resendInvitation(AxSpaceInvitation invite) async {
    try {
      try {
        await widget.dataSource.expireSpaceInvitation(
          spaceId: widget.space.id,
          invitationId: invite.id,
        );
      } catch (_) {}
      await widget.dataSource.inviteSpaceMember(
        spaceId: widget.space.id,
        email: invite.email,
        role: invite.role.isNotEmpty ? invite.role : 'collaborator',
      );
      _message('Invitation resent to ${invite.email}.');
      await _queries.refreshMembers(widget.space.id, includeMembers: false);
    } catch (error) {
      _message(error.toString());
    }
  }
}
