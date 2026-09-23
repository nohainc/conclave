import 'package:flutter/material.dart';

import '../../studio/studio_models.dart';

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.projects,
    required this.hosts,
    required this.workers,
    required this.accounts,
    required this.run,
    required this.openFindingCount,
    required this.usageTokens,
    required this.usageCostMicros,
    required this.onOpenHosts,
    required this.onOpenWorkers,
    required this.onOpenAccounts,
    required this.onOpenUsage,
    required this.onOpenProject,
    required this.onOpenChat,
    required this.onOpenRun,
    required this.onCreateProject,
  });

  final List<StudioProject> projects;
  final List<StudioAgent> hosts;
  final List<StudioWorker> workers;
  final List<StudioCredentialProfile> accounts;
  final StudioRun? run;
  final int openFindingCount;
  final int usageTokens;
  final int usageCostMicros;
  final VoidCallback onOpenHosts;
  final VoidCallback onOpenWorkers;
  final VoidCallback onOpenAccounts;
  final VoidCallback onOpenUsage;
  final ValueChanged<String> onOpenProject;
  final void Function(String projectId, String chatId) onOpenChat;
  final void Function(String projectId, String runId) onOpenRun;
  final VoidCallback onCreateProject;

  bool get isNewWorkspace => projects.isEmpty;

  @override
  Widget build(BuildContext context) => isNewWorkspace
      ? _GettingStarted(
          onOpenHosts: onOpenHosts,
          onOpenWorkers: onOpenWorkers,
          onOpenAccounts: onOpenAccounts,
          onCreateProject: onCreateProject,
        )
      : _EstablishedHome(
          projects: projects,
          hosts: hosts,
          workers: workers,
          accounts: accounts,
          run: run,
          openFindingCount: openFindingCount,
          usageTokens: usageTokens,
          usageCostMicros: usageCostMicros,
          onOpenHosts: onOpenHosts,
          onOpenWorkers: onOpenWorkers,
          onOpenAccounts: onOpenAccounts,
          onOpenUsage: onOpenUsage,
          onOpenProject: onOpenProject,
          onOpenChat: onOpenChat,
          onOpenRun: onOpenRun,
        );
}

class _GettingStarted extends StatelessWidget {
  const _GettingStarted({
    required this.onOpenHosts,
    required this.onOpenWorkers,
    required this.onOpenAccounts,
    required this.onCreateProject,
  });

  final VoidCallback onOpenHosts;
  final VoidCallback onOpenWorkers;
  final VoidCallback onOpenAccounts;
  final VoidCallback onCreateProject;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Getting started',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text(
              'Set up the pieces Conclave AX needs, then make your first request.',
              style: TextStyle(color: Color(0xff777683), fontSize: 14)),
          const SizedBox(height: 28),
          _SetupStep(
              number: '1',
              title: 'Host',
              detail: 'Connect a machine where Workers can run.',
              action: 'Add Host',
              onPressed: onOpenHosts),
          _SetupStep(
              number: '2',
              title: 'Worker',
              detail: 'Choose the AI integration you want to use.',
              action: 'View Workers',
              onPressed: onOpenWorkers),
          _SetupStep(
              number: '3',
              title: 'AI Account',
              detail: 'Connect an Account privately or use a shared one.',
              action: 'Open Accounts',
              onPressed: onOpenAccounts),
          _SetupStep(
              number: '4',
              title: 'Project',
              detail: 'Create a Project to organize your work.',
              action: 'Create project',
              onPressed: onCreateProject),
          const Card(
            color: Color(0xfff1efff),
            child: ListTile(
              leading:
                  Icon(Icons.play_circle_outline, color: Color(0xff6254d9)),
              title: Text('First request',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(
                  'Once your Project is ready, start a Chat and describe what you want to accomplish.'),
              trailing: Icon(Icons.arrow_forward_rounded),
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
    required this.accounts,
    required this.run,
    required this.openFindingCount,
    required this.usageTokens,
    required this.usageCostMicros,
    required this.onOpenHosts,
    required this.onOpenWorkers,
    required this.onOpenAccounts,
    required this.onOpenUsage,
    required this.onOpenProject,
    required this.onOpenChat,
    required this.onOpenRun,
  });

  final List<StudioProject> projects;
  final List<StudioAgent> hosts;
  final List<StudioWorker> workers;
  final List<StudioCredentialProfile> accounts;
  final StudioRun? run;
  final int openFindingCount;
  final int usageTokens;
  final int usageCostMicros;
  final VoidCallback onOpenHosts;
  final VoidCallback onOpenWorkers;
  final VoidCallback onOpenAccounts;
  final VoidCallback onOpenUsage;
  final ValueChanged<String> onOpenProject;
  final void Function(String projectId, String chatId) onOpenChat;
  final void Function(String projectId, String runId) onOpenRun;

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
      const Text('Your Workspace at a glance.',
          style: TextStyle(color: Color(0xff777683), fontSize: 14)),
      const SizedBox(height: 24),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          flex: 2,
          child: _HomeCard(
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
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _HomeCard(
            title: 'Attention required',
            icon: Icons.flag_outlined,
            child: Text(openFindingCount == 0
                ? 'Nothing needs your attention.'
                : '$openFindingCount open finding${openFindingCount == 1 ? '' : 's'}'),
          ),
        ),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: _MetricCard('Hosts', '${hosts.length}', onOpenHosts)),
        const SizedBox(width: 12),
        Expanded(
            child: _MetricCard('Workers', '${workers.length}', onOpenWorkers)),
        const SizedBox(width: 12),
        Expanded(
            child:
                _MetricCard('Accounts', '${accounts.length}', onOpenAccounts)),
        const SizedBox(width: 12),
        Expanded(
            child:
                _MetricCard('Usage', _formatTokens(usageTokens), onOpenUsage)),
      ]),
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

  static String _formatTokens(int tokens) => tokens >= 1000
      ? '${(tokens / 1000).toStringAsFixed(1)}k tokens'
      : '$tokens tokens';
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
              Icon(icon, size: 18, color: const Color(0xff6254d9)),
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
              Text(title, style: const TextStyle(color: Color(0xff777683))),
              const SizedBox(height: 6),
              Text(value,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      );
}
