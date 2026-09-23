import 'package:flutter/material.dart';

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
                  child: Row(
                    children: [
                      Text('${project.chats.length} chats'),
                      const Spacer(),
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
    required this.onCreateChat,
    required this.onOpenChat,
    required this.onEdit,
    required this.onArchive,
    required this.onDelete,
  });

  final StudioProject project;
  final VoidCallback onCreateChat;
  final ValueChanged<String> onOpenChat;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(project.name,
              style:
                  const TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('Project overview',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13)),
          const SizedBox(height: 24),
          _ProjectPanel(
            title: 'Project details',
            subtitle: project.description.isEmpty
                ? 'Add context and execution preferences for this Project.'
                : project.description,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit settings'),
                ),
                OutlinedButton.icon(
                  onPressed: onArchive,
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('Archive'),
                ),
                TextButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete'),
                ),
              ],
            ),
          ),
          _ProjectPanel(
            title: 'Chats',
            subtitle: 'Continue a conversation or start a new one.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (project.chats.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('No chats yet. Start the first one below.'),
                  ),
                ...project.chats.map((chat) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(chat.title),
                      subtitle: Text(chat.lastActivity),
                      onTap: () => onOpenChat(chat.id),
                    )),
                FilledButton.icon(
                  onPressed: onCreateChat,
                  icon: const Icon(Icons.add),
                  label: Text(
                      project.chats.isEmpty ? 'Start first chat' : 'New chat'),
                ),
              ],
            ),
          ),
        ],
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
