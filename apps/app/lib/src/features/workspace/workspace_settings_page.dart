import 'package:flutter/material.dart';

import '../../studio/studio_data.dart';
import '../../studio/studio_models.dart';

class WorkspaceSettingsPage extends StatefulWidget {
  const WorkspaceSettingsPage({
    super.key,
    required this.workspaceId,
    required this.workspaceName,
    required this.dataSource,
    this.hostCount = 0,
    this.accountCount = 0,
  });

  final String workspaceId;
  final String workspaceName;
  final StudioDataSource dataSource;
  final int hostCount;
  final int accountCount;

  @override
  State<WorkspaceSettingsPage> createState() => _WorkspaceSettingsPageState();
}

class _WorkspaceSettingsPageState extends State<WorkspaceSettingsPage> {
  late final TextEditingController nameController;
  List<StudioWorkspaceMember> members = const [];
  List<StudioWorkspaceInvitation> invitations = const [];
  List<StudioAuditEntry> audit = const [];
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(text: widget.workspaceName);
    _load();
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final loadedMembers = await widget.dataSource
          .loadWorkspaceMembers(workspaceId: widget.workspaceId);
      List<StudioWorkspaceInvitation> loadedInvitations = const [];
      List<StudioAuditEntry> loadedAudit = const [];
      // Invitations and audit are intentionally restricted to managers/readers.
      // A regular member can still use General and see the member directory.
      try {
        loadedInvitations = await widget.dataSource
            .loadWorkspaceInvitations(workspaceId: widget.workspaceId);
      } catch (_) {}
      try {
        loadedAudit = await widget.dataSource
            .loadWorkspaceAudit(workspaceId: widget.workspaceId);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        members = loadedMembers;
        invitations = loadedInvitations;
        audit = loadedAudit;
        loading = false;
      });
    } catch (value) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = value.toString();
      });
    }
  }

  void _message(String text, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: isError ? Colors.red.shade700 : null,
    ));
  }

  Future<void> _saveName() async {
    final name = nameController.text.trim();
    if (name.isEmpty) {
      _message('Enter a Workspace name.', isError: true);
      return;
    }
    try {
      await widget.dataSource
          .updateWorkspace(workspaceId: widget.workspaceId, name: name);
      _message('Workspace name saved.');
      await _load();
    } catch (value) {
      _message(value.toString(), isError: true);
    }
  }

  Future<void> _invite() async {
    final emailController = TextEditingController();
    var role = 'member';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Invite member'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: emailController,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email address'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: role,
              decoration: const InputDecoration(labelText: 'Role'),
              items: const [
                DropdownMenuItem(value: 'admin', child: Text('Admin')),
                DropdownMenuItem(value: 'member', child: Text('Member')),
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
    final email = emailController.text.trim();
    emailController.dispose();
    if (confirmed != true || email.isEmpty) return;
    try {
      await widget.dataSource.inviteWorkspaceMember(
          workspaceId: widget.workspaceId, email: email, role: role);
      _message('Invitation sent to $email.');
      await _load();
    } catch (value) {
      _message(value.toString(), isError: true);
    }
  }

  Future<void> _changeRole(StudioWorkspaceMember member) async {
    final role = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Role for ${member.displayName}'),
        children: ['admin', 'member', 'viewer']
            .map((value) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(dialogContext, value),
                  child: Text(value[0].toUpperCase() + value.substring(1)),
                ))
            .toList(),
      ),
    );
    if (role == null || role == member.role) return;
    try {
      await widget.dataSource.changeWorkspaceMemberRole(
          workspaceId: widget.workspaceId, userId: member.userId, role: role);
      _message('Member role updated.');
      await _load();
    } catch (value) {
      _message(value.toString(), isError: true);
    }
  }

  Future<void> _setStatus(StudioWorkspaceMember member, String status) async {
    try {
      await widget.dataSource.setWorkspaceMemberStatus(
          workspaceId: widget.workspaceId,
          userId: member.userId,
          status: status);
      _message(status == 'remove' ? 'Member removed.' : 'Member status saved.');
      await _load();
    } catch (value) {
      _message(value.toString(), isError: true);
    }
  }

  Future<void> _expire(StudioWorkspaceInvitation invitation) async {
    try {
      await widget.dataSource.expireWorkspaceInvitation(
          workspaceId: widget.workspaceId, invitationId: invitation.id);
      _message('Invitation expired.');
      await _load();
    } catch (value) {
      _message(value.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 5,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Workspace settings',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('Manage Workspace access, sharing, and security.',
              style: TextStyle(color: Color(0xff777683), fontSize: 13)),
          const SizedBox(height: 18),
          const TabBar(isScrollable: true, tabs: [
            Tab(text: 'General'),
            Tab(text: 'Members'),
            Tab(text: 'Invitations'),
            Tab(text: 'Permissions'),
            Tab(text: 'Audit'),
          ]),
          const SizedBox(height: 18),
          if (loading)
            const LinearProgressIndicator()
          else if (error != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: const Text('Workspace settings could not load'),
                subtitle: Text(error!),
                trailing: IconButton(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Retry'),
              ),
            )
          else
            SizedBox(
              height: 520,
              child: TabBarView(children: [
                _generalTab(),
                _membersTab(),
                _invitationsTab(),
                _permissionsTab(),
                _auditTab(),
              ]),
            ),
        ]),
      );

  Widget _generalTab() =>
      ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('General',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              TextField(
                  controller: nameController,
                  decoration:
                      const InputDecoration(labelText: 'Workspace name')),
              const SizedBox(height: 12),
              Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                      onPressed: _saveName, child: const Text('Save changes'))),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Shared resources',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                  '${members.length} members can access this Workspace. ${widget.hostCount} Hosts and ${widget.accountCount} AI Accounts are visible to authorized members.'),
              const SizedBox(height: 8),
              const Text(
                  'Private AI Accounts remain private unless explicitly shared.',
                  style: TextStyle(color: Color(0xff777683))),
            ]),
          ),
        ),
      ]);

  Widget _membersTab() =>
      ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
                onPressed: _invite,
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Invite member'))),
        const SizedBox(height: 12),
        if (members.isEmpty)
          const Card(child: ListTile(title: Text('No members found')))
        else
          ...members.map((member) => Card(
                child: ListTile(
                  leading: CircleAvatar(
                      child: Text(member.displayName.isEmpty
                          ? '?'
                          : member.displayName[0].toUpperCase())),
                  title: Text(member.displayName),
                  subtitle: Text('${member.email} · ${member.status}'),
                  trailing: member.role == 'owner'
                      ? const Chip(label: Text('Owner'))
                      : PopupMenuButton<String>(
                          tooltip: 'Member actions',
                          onSelected: (action) {
                            if (action == 'role') {
                              _changeRole(member);
                            }
                            if (action == 'suspend') {
                              _setStatus(member, 'suspend');
                            }
                            if (action == 'activate') {
                              _setStatus(member, 'activate');
                            }
                            if (action == 'remove') {
                              _setStatus(member, 'remove');
                            }
                          },
                          itemBuilder: (context) => [
                            const PopupMenuItem(
                                value: 'role', child: Text('Change role')),
                            PopupMenuItem(
                                value: member.status == 'suspended'
                                    ? 'activate'
                                    : 'suspend',
                                child: Text(member.status == 'suspended'
                                    ? 'Activate'
                                    : 'Suspend')),
                            const PopupMenuItem(
                                value: 'remove', child: Text('Remove')),
                          ],
                        ),
                ),
              )),
      ]);

  Widget _invitationsTab() => ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: invitations.isEmpty
            ? [const Card(child: ListTile(title: Text('No invitations')))]
            : invitations
                .map((invitation) => Card(
                      child: ListTile(
                        title: Text(invitation.email),
                        subtitle: Text(
                            '${invitation.role} · ${invitation.status} · expires ${invitation.expiresAt}'),
                        trailing: invitation.status == 'pending'
                            ? TextButton(
                                onPressed: () => _expire(invitation),
                                child: const Text('Expire'))
                            : null,
                      ),
                    ))
                .toList(),
      );

  Widget _permissionsTab() => ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const Card(
              child: Padding(
                  padding: EdgeInsets.all(18),
                  child: Text(
                      'Permissions are enforced by Conclave Cloud on every request. Workspace roles never reveal private AI Account secrets.'))),
          ...const [
            ('Owner', 'All Workspace, Host, Account, and audit controls.'),
            ('Admin', 'Members, invitations, Hosts, Workers, and sharing.'),
            (
              'Member',
              'Projects, execution, Host use, and permitted Accounts.'
            ),
            ('Viewer', 'Read-only access where granted.'),
          ].map((entry) => Card(
              child:
                  ListTile(title: Text(entry.$1), subtitle: Text(entry.$2)))),
        ],
      );

  Widget _auditTab() => ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: audit.isEmpty
            ? [const Card(child: ListTile(title: Text('No audit events')))]
            : audit
                .map((entry) => Card(
                      child: ListTile(
                        leading: const Icon(Icons.history),
                        title: Text(entry.action),
                        subtitle: Text(
                            '${entry.targetType}/${entry.targetId} · ${entry.createdAt}'),
                      ),
                    ))
                .toList(),
      );
}
