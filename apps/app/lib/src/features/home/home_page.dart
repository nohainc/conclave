import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.projects,
    required this.hosts,
    required this.workers,
    required this.run,
    required this.openFindingCount,
    required this.onOpenHosts,
    required this.onOpenWorkers,
    required this.onOpenProject,
    required this.onOpenChat,
    required this.onOpenRun,
    required this.onCreateProject,
    required this.onOpenArchivedProjects,
  });

  final List<StudioProject> projects;
  final List<StudioAgent> hosts;
  final List<StudioWorker> workers;
  final StudioRun? run;
  final int openFindingCount;
  final VoidCallback onOpenHosts;
  final VoidCallback onOpenWorkers;
  final ValueChanged<String> onOpenProject;
  final void Function(String projectId, String chatId) onOpenChat;
  final void Function(String projectId, String runId) onOpenRun;
  final VoidCallback onCreateProject;
  final VoidCallback onOpenArchivedProjects;

  bool get isNewWorkspace => projects.isEmpty;

  @override
  Widget build(BuildContext context) => isNewWorkspace
      ? _GettingStarted(
          onOpenHosts: onOpenHosts,
          onOpenWorkers: onOpenWorkers,
          onCreateProject: onCreateProject,
          onOpenArchivedProjects: onOpenArchivedProjects,
        )
      : _EstablishedHome(
          projects: projects,
          hosts: hosts,
          workers: workers,
          run: run,
          openFindingCount: openFindingCount,
          onOpenHosts: onOpenHosts,
          onOpenWorkers: onOpenWorkers,
          onOpenProject: onOpenProject,
          onOpenChat: onOpenChat,
          onOpenRun: onOpenRun,
          onOpenArchivedProjects: onOpenArchivedProjects,
        );
}

class _GettingStarted extends StatelessWidget {
  const _GettingStarted({
    required this.onOpenHosts,
    required this.onOpenWorkers,
    required this.onCreateProject,
    required this.onOpenArchivedProjects,
  });

  final VoidCallback onOpenHosts;
  final VoidCallback onOpenWorkers;
  final VoidCallback onCreateProject;
  final VoidCallback onOpenArchivedProjects;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Getting started',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(
              'Set up the pieces Conclave AX needs, then make your first request.',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 14)),
          const SizedBox(height: 28),
          _SetupStep(
              number: '1',
              title: 'Workspace',
              detail: 'Connect a machine where Workers can run.',
              action: 'Add Workspace',
              onPressed: onOpenHosts),
          _SetupStep(
              number: '2',
              title: 'Worker',
              detail: 'Choose the AI integration you want to use.',
              action: 'View Workers',
              onPressed: onOpenWorkers),
          _SetupStep(
              number: '3',
              title: 'Project',
              detail: 'Create a Project to organize your work.',
              action: 'Create project',
              onPressed: onCreateProject),
          _SetupStep(
              number: '4',
              title: 'Archived Projects',
              detail: 'Restore a Project that was archived earlier.',
              action: 'View archived',
              onPressed: onOpenArchivedProjects),
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: ListTile(
              leading: Icon(Icons.play_circle_outline,
                  color: Theme.of(context).colorScheme.primary),
              title: const Text('First request',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: const Text(
                  'Once your Project is ready, start a Chat and describe what you want to accomplish.'),
              trailing: const Icon(Icons.arrow_forward_rounded),
            ),
          ),
        ],
      );
}

class _SetupStep extends StatelessWidget {
  const _SetupStep({
    required this.number,
    required this.title,
    required this.detail,
    required this.action,
    required this.onPressed,
  });

  final String number;
  final String title;
  final String detail;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: ListTile(
          leading: CircleAvatar(
            radius: 16,
            backgroundColor: const Color(0xffeeecff),
            child: Text(number,
                style: const TextStyle(
                    color: Color(0xff5143b8), fontWeight: FontWeight.w700)),
          ),
          title:
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(detail),
          trailing: OutlinedButton(onPressed: onPressed, child: Text(action)),
        ),
      );
}

class _EstablishedHome extends StatelessWidget {
  const _EstablishedHome({
    required this.projects,
    required this.hosts,
    required this.workers,
    required this.run,
    required this.openFindingCount,
    required this.onOpenHosts,
    required this.onOpenWorkers,
    required this.onOpenProject,
    required this.onOpenChat,
    required this.onOpenRun,
    required this.onOpenArchivedProjects,
  });

  final List<StudioProject> projects;
  final List<StudioAgent> hosts;
  final List<StudioWorker> workers;
  final StudioRun? run;
  final int openFindingCount;
  final VoidCallback onOpenHosts;
  final VoidCallback onOpenWorkers;
  final ValueChanged<String> onOpenProject;
  final void Function(String projectId, String chatId) onOpenChat;
  final void Function(String projectId, String runId) onOpenRun;
  final VoidCallback onOpenArchivedProjects;

  @override
  Widget build(BuildContext context) {
    final recentProjects = projects.take(3);
    final recentChats = projects
        .expand((project) => project.chats.map((chat) => (project, chat)))
        .take(4);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Home',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: onOpenArchivedProjects,
          icon: const Icon(Icons.archive_outlined, size: 16),
          label: const Text('Archived Projects'),
        ),
      ),
      const SizedBox(height: 12),
      Text('Your Workspace at a glance.',
          style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 14)),
      const SizedBox(height: 24),
      LayoutBuilder(builder: (context, constraints) {
        final narrow = constraints.maxWidth < 620;
        final cards = [
          _HomeCard(
            title: 'Active Runs',
            icon: Icons.play_circle_outline,
            child: run == null
                ? const Text('No active Runs')
                : ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(run!.objective),
                    subtitle: Text(
                        '${run!.completedTaskCount}/${run!.taskCount} tasks complete'),
                    trailing: OutlinedButton(
                      onPressed: () => onOpenRun(projects.first.id, run!.id),
                      child: const Text('Open run details'),
                    ),
                  ),
          ),
          _HomeCard(
            title: 'Attention required',
            icon: Icons.flag_outlined,
            child: Text(openFindingCount == 0
                ? 'Nothing needs your attention.'
                : '$openFindingCount open finding${openFindingCount == 1 ? '' : 's'}'),
          ),
        ];
        return narrow
            ? Column(children: [cards[0], const SizedBox(height: 12), cards[1]])
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 2, child: cards[0]),
                const SizedBox(width: 16),
                Expanded(child: cards[1]),
              ]);
      }),
      const SizedBox(height: 16),
      LayoutBuilder(builder: (context, constraints) {
        final cards = [
          _MetricCard('Projects', '${projects.length}',
              () => onOpenProject(projects.first.id)),
          _MetricCard('Workspaces', '${hosts.length}', onOpenHosts),
          _MetricCard('Workers', '${workers.length}', onOpenWorkers),
        ];
        return constraints.maxWidth < 620
            ? Wrap(spacing: 12, runSpacing: 12, children: cards)
            : Row(children: [
                for (var index = 0; index < cards.length; index++) ...[
                  Expanded(child: cards[index]),
                  if (index < cards.length - 1) const SizedBox(width: 12),
                ],
              ]);
      }),
      const SizedBox(height: 24),
      _HomeCard(
        title: 'Recent Projects',
        icon: Icons.folder_outlined,
        child: Column(
          children: recentProjects
              .map((project) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(project.name),
                    subtitle: Text(project.lastActivity),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => onOpenProject(project.id),
                  ))
              .toList(),
        ),
      ),
      const SizedBox(height: 16),
      _HomeCard(
        title: 'Recent Chats',
        icon: Icons.chat_bubble_outline,
        child: Column(
          children: recentChats
              .map((entry) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.$2.title),
                    subtitle: Text(entry.$1.name),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => onOpenChat(entry.$1.id, entry.$2.id),
                  ))
              .toList(),
        ),
      ),
    ]);
  }
}

class _HomeCard extends StatelessWidget {
  const _HomeCard(
      {required this.title, required this.icon, required this.child});

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon,
                  size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: 12),
            child,
          ]),
        ),
      );
}

class _MetricCard extends StatelessWidget {
  const _MetricCard(this.title, this.value, this.onTap);

  final String title;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 6),
              Text(value,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      );
}
