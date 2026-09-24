import 'package:flutter/material.dart';

import '../../studio/studio_data.dart';
import '../../studio/studio_models.dart';

class ProjectsPage extends StatelessWidget {
  const ProjectsPage({
    super.key,
    required this.projects,
    required this.onCreateProject,
    required this.onOpenProject,
    required this.onDeleteProject,
  });

  final List<StudioProject> projects;
  final VoidCallback onCreateProject;
  final ValueChanged<String> onOpenProject;
  final ValueChanged<String> onDeleteProject;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          const Text('Projects',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('Projects organize Chats, Runs, artifacts, and evidence.',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13)),
          const SizedBox(height: 24),
          if (projects.isEmpty)
            _ProjectPanel(
              title: 'No projects yet',
              subtitle: 'Create a Project to start your first Chat.',
              child: FilledButton.icon(
                onPressed: onCreateProject,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Create project'),
              ),
            )
          else
            ...projects.map((project) => _ProjectPanel(
                  title: project.name,
                  subtitle: project.repository.isEmpty
                      ? 'No repository connected'
                      : project.repository,
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('${project.chats.length} chats'),
                      OutlinedButton(
                        onPressed: () => onOpenProject(project.id),
                        child: const Text('Open project'),
                      ),
                      IconButton(
                        tooltip: 'Delete project',
                        onPressed: () => onDeleteProject(project.id),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                )),
        ],
      );
}

class ProjectPage extends StatelessWidget {
  const ProjectPage({
    super.key,
    required this.project,
    required this.dataSource,
    required this.onCreateChat,
    required this.onOpenChat,
    required this.onEdit,
    required this.onArchive,
    required this.onDelete,
  });

  final StudioProject project;
  final StudioDataSource dataSource;
  final VoidCallback onCreateChat;
  final ValueChanged<String> onOpenChat;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => _ProjectWorkspace(
        project: project,
        dataSource: dataSource,
        onCreateChat: onCreateChat,
        onOpenChat: onOpenChat,
        onEdit: onEdit,
        onArchive: onArchive,
        onDelete: onDelete,
      );
}

class _ProjectWorkspace extends StatefulWidget {
  const _ProjectWorkspace({
    required this.project,
    required this.dataSource,
    required this.onCreateChat,
    required this.onOpenChat,
    required this.onEdit,
    required this.onArchive,
    required this.onDelete,
  });

  final StudioProject project;
  final StudioDataSource dataSource;
  final VoidCallback onCreateChat;
  final ValueChanged<String> onOpenChat;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  @override
  State<_ProjectWorkspace> createState() => _ProjectWorkspaceState();
}

class _ProjectWorkspaceState extends State<_ProjectWorkspace> {
  List<StudioProjectMember> members = const [];
  List<StudioProjectInvitation> invitations = const [];
  List<StudioAuditEntry> audit = const [];
  bool loading = true;

  bool get canManage =>
      widget.project.role == 'owner' || widget.project.role == 'collaborator';
  bool get isOwner => widget.project.role == 'owner';

  @override
  void initState() {
    super.initState();
    _loadCollaboration();
  }

  Future<void> _loadCollaboration() async {
    try {
      final loaded = await Future.wait([
        widget.dataSource.loadProjectMembers(projectId: widget.project.id),
        widget.dataSource.loadProjectInvitations(projectId: widget.project.id),
        widget.dataSource.loadProjectAudit(projectId: widget.project.id),
      ]);
      if (!mounted) return;
      setState(() {
        members = loaded[0] as List<StudioProjectMember>;
        invitations = loaded[1] as List<StudioProjectInvitation>;
        audit = loaded[2] as List<StudioAuditEntry>;
        loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  void _message(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

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
    await widget.dataSource.removeProjectMember(
        projectId: widget.project.id, userId: member.userId);
    _message('${member.displayName} was removed from the Project.');
    await _loadCollaboration();
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 7,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 10,
            children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.project.name,
                    style: const TextStyle(
                        fontSize: 25, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text('Project collaboration and execution',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 13)),
              ]),
              if (isOwner)
                FilledButton.icon(
                    onPressed: _share,
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('Share Project')),
            ],
          ),
          const SizedBox(height: 18),
          const TabBar(isScrollable: true, tabs: [
            Tab(text: 'Overview'),
            Tab(text: 'Chats'),
            Tab(text: 'Runs'),
            Tab(text: 'Artifacts'),
            Tab(text: 'Members'),
            Tab(text: 'Execution'),
            Tab(text: 'Settings'),
          ]),
          const SizedBox(height: 16),
          Expanded(
              child: TabBarView(children: [
            _overview(),
            _chats(),
            _emptySection(
                'Runs', 'Runs created from this Project appear here.'),
            _emptySection('Artifacts',
                'Artifacts and findings produced by this Project appear here.'),
            _members(),
            _emptySection('Execution',
                'Choose Workspaces and review the effective execution access for this Project.'),
            _settings(),
          ])),
        ]),
      );

  Widget _overview() => ListView(children: [
        _ProjectPanel(
            title: 'Project overview',
            subtitle: widget.project.description.isEmpty
                ? 'A shared home for Chats, Runs, artifacts, and evidence.'
                : widget.project.description,
            child: Text('Role: ${widget.project.role}')),
        _ProjectPanel(
            title: 'Execution summary',
            subtitle:
                'Execution capacity is configured independently from Project collaboration.',
            child: const Text(
                'No execution summary available yet. Open Execution to connect a Workspace.')),
      ]);

  Widget _chats() => ListView(children: [
        _ProjectPanel(
            title: 'Chats',
            subtitle: 'Continue a conversation or start a new one.',
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (widget.project.chats.isEmpty)
                const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('No chats yet. Start the first one below.')),
              ...widget.project.chats.map((chat) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(chat.title),
                  subtitle: Text(chat.lastActivity),
                  onTap: () => widget.onOpenChat(chat.id))),
              if (canManage)
                FilledButton.icon(
                    onPressed: widget.onCreateChat,
                    icon: const Icon(Icons.add),
                    label: Text(widget.project.chats.isEmpty
                        ? 'Start first chat'
                        : 'New chat')),
            ])),
      ]);

  Widget _members() => ListView(children: [
        _ProjectPanel(
            title: 'Members',
            subtitle:
                'Project roles control collaboration. They do not grant Workspace access.',
            child: loading
                ? const LinearProgressIndicator()
                : Column(children: [
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
                              ))),
                    if (invitations.isNotEmpty) ...[
                      const Divider(),
                      const Align(
                          alignment: Alignment.centerLeft,
                          child: Text('Pending invitations',
                              style: TextStyle(fontWeight: FontWeight.w700))),
                      ...invitations.map((invite) => ListTile(
                          title: Text(invite.email),
                          subtitle: Text(invite.role),
                          trailing: const Chip(label: Text('Pending')))),
                    ],
                  ])),
      ]);

  Widget _settings() => ListView(children: [
        _ProjectPanel(
            title: 'Project settings',
            subtitle:
                'Only the Project owner can change settings or delete the Project.',
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                  onPressed: isOwner ? widget.onEdit : null,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit settings')),
              OutlinedButton.icon(
                  onPressed: isOwner ? widget.onArchive : null,
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('Archive')),
              TextButton.icon(
                  onPressed: isOwner ? widget.onDelete : null,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete')),
            ])),
        _ProjectPanel(
          title: 'Project audit',
          subtitle:
              'Membership and sharing changes are recorded for this Project.',
          child: audit.isEmpty
              ? const Text('No audit events yet.')
              : Column(
                  children: audit
                      .take(8)
                      .map((entry) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(entry.action),
                            subtitle: Text(
                                '${entry.targetType} · ${entry.createdAt}'),
                          ))
                      .toList(),
                ),
        ),
      ]);

  Widget _emptySection(String title, String message) => ListView(children: [
        _ProjectPanel(
            title: title,
            subtitle: message,
            child: const Text('Nothing to show yet.'))
      ]);
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
