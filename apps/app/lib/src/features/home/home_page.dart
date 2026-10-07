import 'package:flutter/material.dart';

import '../../ax/ax_models.dart';
import '../../brand.dart';

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.projects,
    required this.workspaces,
    required this.workers,
    required this.run,
    required this.openFindingCount,
    required this.onOpenWorkspaces,
    required this.onOpenProject,
    required this.onOpenRun,
    required this.onCreateProject,
    this.onOpenArchivedProjects,
    this.invitations = const [],
    this.attentionItems = const [],
    this.continueWorkItems = const [],
    this.productUpdates = const [],
    this.aiUpdates = const [],
    this.onAcceptInvitation,
    this.onDeclineInvitation,
    this.onOpenWorkstream,
  });

  final List<AxProject> projects;
  final List<AxWorkspace> workspaces;
  final List<AxWorker> workers;
  final AxRun? run;
  final int openFindingCount;
  final VoidCallback onOpenWorkspaces;
  final ValueChanged<String> onOpenProject;
  final void Function(String projectId, String runId) onOpenRun;
  final VoidCallback onCreateProject;
  final VoidCallback? onOpenArchivedProjects;
  final List<AxProjectInvitation> invitations;
  final List<AxHomeAttentionItem> attentionItems;
  final List<AxContinueWorkItem> continueWorkItems;
  final List<AxProductUpdate> productUpdates;
  final List<AxAiUpdate> aiUpdates;
  final ValueChanged<AxProjectInvitation>? onAcceptInvitation;
  final ValueChanged<AxProjectInvitation>? onDeclineInvitation;
  final void Function(String projectId, String workstreamId)? onOpenWorkstream;

  /// New-user experience is active when user has zero projects.
  bool get isNewUser => projects.isEmpty;

  @override
  Widget build(BuildContext context) => isNewUser
      ? NewUserHome(
          onCreateProject: onCreateProject,
          onOpenWorkspaces: onOpenWorkspaces,
          invitations: invitations,
          onAcceptInvitation: onAcceptInvitation,
          onDeclineInvitation: onDeclineInvitation,
        )
      : EstablishedUserHome(
          projects: projects,
          workspaces: workspaces,
          workers: workers,
          invitations: invitations,
          attentionItems: attentionItems,
          continueWorkItems: continueWorkItems,
          productUpdates: productUpdates,
          aiUpdates: aiUpdates,
          onAcceptInvitation: onAcceptInvitation,
          onDeclineInvitation: onDeclineInvitation,
          run: run,
          openFindingCount: openFindingCount,
          onOpenWorkspaces: onOpenWorkspaces,
          onOpenProject: onOpenProject,
          onOpenRun: onOpenRun,
          onOpenWorkstream: onOpenWorkstream,
        );
}

class NewUserHome extends StatelessWidget {
  const NewUserHome({
    super.key,
    required this.onCreateProject,
    required this.onOpenWorkspaces,
    this.invitations = const [],
    this.onAcceptInvitation,
    this.onDeclineInvitation,
  });

  final VoidCallback onCreateProject;
  final VoidCallback onOpenWorkspaces;
  final List<AxProjectInvitation> invitations;
  final ValueChanged<AxProjectInvitation>? onAcceptInvitation;
  final ValueChanged<AxProjectInvitation>? onDeclineInvitation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasInvitations = invitations.isNotEmpty;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Welcome to Conclave AX',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Bring your people and AI together.',
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 24),

          // If invitations exist, Join a Project takes priority
          if (hasInvitations) ...[
            _JoinProjectPriorityCard(
              invitations: invitations,
              onAccept: onAcceptInvitation,
              onDecline: onDeclineInvitation,
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                'or',
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 16),
            _CreateFirstProjectCard(
              onCreateProject: onCreateProject,
              isSecondary: true,
            ),
          ] else ...[
            _CreateFirstProjectCard(
              onCreateProject: onCreateProject,
              isSecondary: false,
            ),
          ],

          const SizedBox(height: 28),
          const Text(
            'How Conclave AX works',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 700;
              return GridView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: isWide ? 3 : 1,
                  mainAxisExtent: isWide ? 160 : 100,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                ),
                children: const [
                  _OnboardingValueCard(
                    icon: Icons.people_alt_outlined,
                    title: 'People first',
                    description:
                        'Invite teammates, family, and collaborators to work together with shared AI.',
                  ),
                  _OnboardingValueCard(
                    icon: Icons.shield_outlined,
                    title: 'Private credentials',
                    description:
                        'Share AI access in projects without ever exposing your API keys or machine logins.',
                  ),
                  _OnboardingValueCard(
                    icon: Icons.forum_outlined,
                    title: 'Shared conversations',
                    description:
                        'Keep context intact across team members and switch AI models seamlessly.',
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 28),

          // Advanced local execution path (visually secondary)
          _AdvancedWorkspaceCard(
            onOpenWorkspaces: onOpenWorkspaces,
          ),
        ],
      ),
    );
  }
}

class _AdvancedWorkspaceCard extends StatelessWidget {
  const _AdvancedWorkspaceCard({required this.onOpenWorkspaces});

  final VoidCallback onOpenWorkspaces;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark
            ? colorScheme.surfaceContainerLow
            : colorScheme.surfaceContainerLowest,
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < 560;
          if (isCompact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.terminal_outlined,
                      size: 20,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Want to use AI or tools running on your computer?',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Connect Conclave Workspace to make local Workers available to your Projects.',
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: onOpenWorkspaces,
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Connect Workspace →'),
                ),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.terminal_outlined,
                size: 24,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Want to use AI or tools running on your computer?',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Connect Conclave Workspace to make local Workers available to your Projects.',
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              OutlinedButton(
                onPressed: onOpenWorkspaces,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Connect Workspace →'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CreateFirstProjectCard extends StatelessWidget {
  const _CreateFirstProjectCard({
    required this.onCreateProject,
    this.isSecondary = false,
  });

  final VoidCallback onCreateProject;
  final bool isSecondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Card(
      elevation: 0,
      color: isSecondary
          ? null
          : (isDark
              ? colorScheme.surfaceContainerHigh
              : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)),
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: isSecondary
              ? colorScheme.outlineVariant.withValues(alpha: 0.6)
              : colorScheme.primary.withValues(alpha: 0.3),
          width: isSecondary ? 1 : 1.5,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.add_circle_outline,
                    color: colorScheme.primary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Create your first Project',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Start a shared space for people, conversations and AI.',
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onCreateProject,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Create Project →'),
            ),
          ],
        ),
      ),
    );
  }
}

class _JoinProjectPriorityCard extends StatelessWidget {
  const _JoinProjectPriorityCard({
    required this.invitations,
    this.onAccept,
    this.onDecline,
  });

  final List<AxProjectInvitation> invitations;
  final ValueChanged<AxProjectInvitation>? onAccept;
  final ValueChanged<AxProjectInvitation>? onDecline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final count = invitations.length;

    return Card(
      elevation: 0,
      color: ConclaveColors.primarySoftColor(isDark),
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color:
              ConclaveColors.primaryForeground(isDark).withValues(alpha: 0.3),
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: ConclaveColors.primarySoftColor(isDark),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.mail_outline,
                    color: ConclaveColors.primaryForeground(isDark),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Join a Project',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: ConclaveColors.primaryForeground(isDark),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'You have $count invitation${count == 1 ? '' : 's'}.',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: ConclaveColors.primaryForeground(isDark)
                              .withValues(alpha: 0.9),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            for (final invite in invitations) ...[
              _InvitationItem(
                invitation: invite,
                onAccept: onAccept != null ? () => onAccept!(invite) : null,
                onDecline: onDecline != null ? () => onDecline!(invite) : null,
              ),
              if (invite != invitations.last) const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _OnboardingValueCard extends StatelessWidget {
  const _OnboardingValueCard({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 24, color: theme.colorScheme.primary),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Text(
                description,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class EstablishedUserHome extends StatelessWidget {
  const EstablishedUserHome({
    super.key,
    required this.projects,
    required this.workspaces,
    required this.workers,
    required this.invitations,
    required this.attentionItems,
    required this.continueWorkItems,
    required this.productUpdates,
    required this.aiUpdates,
    required this.onAcceptInvitation,
    required this.onDeclineInvitation,
    required this.run,
    required this.openFindingCount,
    required this.onOpenWorkspaces,
    required this.onOpenProject,
    required this.onOpenRun,
    this.onOpenWorkstream,
  });

  final List<AxProject> projects;
  final List<AxWorkspace> workspaces;
  final List<AxWorker> workers;
  final List<AxProjectInvitation> invitations;
  final List<AxHomeAttentionItem> attentionItems;
  final List<AxContinueWorkItem> continueWorkItems;
  final List<AxProductUpdate> productUpdates;
  final List<AxAiUpdate> aiUpdates;
  final ValueChanged<AxProjectInvitation>? onAcceptInvitation;
  final ValueChanged<AxProjectInvitation>? onDeclineInvitation;
  final AxRun? run;
  final int openFindingCount;
  final VoidCallback onOpenWorkspaces;
  final ValueChanged<String> onOpenProject;
  final void Function(String projectId, String runId) onOpenRun;
  final void Function(String projectId, String workstreamId)? onOpenWorkstream;

  List<AxProductUpdate> get _effectiveProductUpdates =>
      productUpdates.isNotEmpty ? productUpdates : _defaultProductUpdates;

  List<AxAiUpdate> get _effectiveAiUpdates {
    if (aiUpdates.isNotEmpty) return aiUpdates;
    // Derive relevant AI updates based on available worker types in the workspace/projects
    final availableWorkerTypes = workers.map((w) => w.workerTypeId).toSet();
    return _defaultAiUpdates.where((update) {
      if (availableWorkerTypes.isEmpty) return true;
      return availableWorkerTypes.contains(update.workerTypeId);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final hasPendingInvitations = invitations.isNotEmpty;
    final hasAttention = hasPendingInvitations ||
        attentionItems.isNotEmpty ||
        openFindingCount > 0;
    final hasActiveRun = run != null;
    final hasContinueWork = continueWorkItems.isNotEmpty || projects.isNotEmpty;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Home',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 20),

          // 1. FOR YOU (Actionable Items requiring attention)
          if (hasAttention) ...[
            _SectionHeader(
              title: 'For you',
              badgeCount: invitations.length +
                  attentionItems.length +
                  (openFindingCount > 0 ? 1 : 0),
            ),
            const SizedBox(height: 12),
            if (hasPendingInvitations)
              _PendingInvitationsSection(
                invitations: invitations,
                onAccept: onAcceptInvitation,
                onDecline: onDeclineInvitation,
              ),
            if (hasPendingInvitations &&
                (attentionItems.isNotEmpty || openFindingCount > 0))
              const SizedBox(height: 12),
            for (final item in attentionItems) ...[
              _AttentionCard(
                item: item,
                onTap: () {
                  if (item.projectId != null) {
                    onOpenProject(item.projectId!);
                  }
                },
              ),
              const SizedBox(height: 8),
            ],
            if (openFindingCount > 0 && attentionItems.isEmpty) ...[
              _AttentionCard(
                item: AxHomeAttentionItem(
                  id: 'findings-open',
                  title:
                      '$openFindingCount open finding${openFindingCount == 1 ? '' : 's'} require review',
                  subtitle: 'Review task results and verification evidence',
                  timestampDisplay: 'Needs attention',
                  actionLabel: 'Review',
                  severity: 'action',
                  projectId: projects.isNotEmpty ? projects.first.id : null,
                ),
                onTap: () {
                  if (projects.isNotEmpty) {
                    onOpenProject(projects.first.id);
                  }
                },
              ),
            ],
            const SizedBox(height: 24),
          ],

          // Running Now (Conditional active execution)
          if (hasActiveRun) ...[
            const _SectionHeader(title: 'Running now'),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: Icon(
                  Icons.play_circle_fill,
                  color: Theme.of(context).colorScheme.primary,
                ),
                title: Text(
                  run!.objective,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  '${run!.completedTaskCount}/${run!.taskCount} tasks completed',
                ),
                trailing: FilledButton.tonal(
                  onPressed: () => onOpenRun(projects.first.id, run!.id),
                  child: const Text('Open run details'),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],

          // 2. CONTINUE WORKING (Recent relevant Workstreams)
          if (hasContinueWork) ...[
            const _SectionHeader(title: 'Continue working'),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth > 700;
                final items = continueWorkItems.isNotEmpty
                    ? continueWorkItems
                    : projects
                        .take(3)
                        .map((p) => AxContinueWorkItem(
                              projectId: p.id,
                              projectName: p.name,
                              workstreamId: 'default',
                              workstreamTitle: 'Main Workstream',
                              collaboratorsDisplay: 'You and team AI',
                              lastMessageSnippet:
                                  'Continue conversation and work in context',
                              lastActivityDisplay: p.lastActivity,
                            ))
                        .toList();

                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: isWide ? 2 : 1,
                    mainAxisExtent: 130,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _ContinueWorkCard(
                      item: item,
                      onTap: () {
                        if (onOpenWorkstream != null) {
                          onOpenWorkstream!(item.projectId, item.workstreamId);
                        } else {
                          onOpenProject(item.projectId);
                        }
                      },
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 28),
          ],

          // 3. WHAT'S NEW (Product Updates)
          const _SectionHeader(title: "What's new in Conclave"),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  for (var i = 0; i < _effectiveProductUpdates.length; i++) ...[
                    _ProductUpdateTile(update: _effectiveProductUpdates[i]),
                    if (i < _effectiveProductUpdates.length - 1)
                      const Divider(height: 1),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),

          // 4. AI UPDATES (Changes relevant to available Workers/models)
          if (_effectiveAiUpdates.isNotEmpty) ...[
            const _SectionHeader(title: 'AI updates'),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth > 700;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: isWide ? 2 : 1,
                    mainAxisExtent: 110,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: _effectiveAiUpdates.length,
                  itemBuilder: (context, index) {
                    final update = _effectiveAiUpdates[index];
                    return _AiUpdateCard(update: update);
                  },
                );
              },
            ),
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.badgeCount});

  final String title;
  final int? badgeCount;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        if (badgeCount != null && badgeCount! > 0) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '$badgeCount',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _AttentionCard extends StatelessWidget {
  const _AttentionCard({required this.item, required this.onTap});

  final AxHomeAttentionItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: Icon(
          Icons.notifications_active_outlined,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text(
          item.title,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        subtitle: Text('${item.subtitle} · ${item.timestampDisplay}'),
        trailing: item.actionLabel != null
            ? FilledButton.tonal(
                onPressed: onTap,
                child: Text(item.actionLabel!),
              )
            : const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}

class _ContinueWorkCard extends StatelessWidget {
  const _ContinueWorkCard({required this.item, required this.onTap});

  final AxContinueWorkItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      item.projectName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    item.lastActivityDisplay,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              Text(
                item.workstreamTitle,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      item.collaboratorsDisplay,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Text(
                    'Continue →',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductUpdateTile extends StatelessWidget {
  const _ProductUpdateTile({required this.update});

  final AxProductUpdate update;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              update.dateDisplay,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              update.title,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(update.summary),
      ),
      trailing: const Icon(Icons.arrow_forward_rounded, size: 16),
    );
  }
}

class _AiUpdateCard extends StatelessWidget {
  const _AiUpdateCard({required this.update});

  final AxAiUpdate update;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                _aiDot(update.workerTypeId),
                const SizedBox(width: 6),
                Text(
                  update.workerDisplayName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            Text(
              update.title,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              update.detail,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _aiDot(String typeId) {
    final color = switch (typeId) {
      'chatgpt' => const Color(0xFF10A37F),
      'gemini' => const Color(0xFF3B82F6),
      'claude' => const Color(0xFFD97706),
      _ => Colors.purpleAccent,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}

class _PendingInvitationsSection extends StatelessWidget {
  const _PendingInvitationsSection({
    required this.invitations,
    this.onAccept,
    this.onDecline,
  });

  final List<AxProjectInvitation> invitations;
  final ValueChanged<AxProjectInvitation>? onAccept;
  final ValueChanged<AxProjectInvitation>? onDecline;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      color: ConclaveColors.primarySoftColor(isDark),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.mail_outline,
                  size: 20,
                  color: ConclaveColors.primaryForeground(isDark),
                ),
                const SizedBox(width: 8),
                Text(
                  'Pending invitations (${invitations.length})',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: ConclaveColors.primaryForeground(isDark),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final invite in invitations) ...[
              _InvitationItem(
                invitation: invite,
                onAccept: onAccept != null ? () => onAccept!(invite) : null,
                onDecline: onDecline != null ? () => onDecline!(invite) : null,
              ),
              if (invite != invitations.last) const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _InvitationItem extends StatelessWidget {
  const _InvitationItem({
    required this.invitation,
    this.onAccept,
    this.onDecline,
  });

  final AxProjectInvitation invitation;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: Theme.of(context)
              .colorScheme
              .outlineVariant
              .withValues(alpha: 0.5),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    invitation.projectName.isNotEmpty
                        ? invitation.projectName
                        : 'Project Invitation',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Invited by ${invitation.invitedByDisplay} · ${invitation.role.toUpperCase()}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onDecline != null)
              OutlinedButton(
                onPressed: onDecline,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Decline'),
              ),
            if (onAccept != null) ...[
              const SizedBox(width: 8),
              FilledButton(
                onPressed: onAccept,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Accept'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

const _defaultProductUpdates = [
  AxProductUpdate(
    id: 'update-invitations',
    title: 'Project Invitations',
    summary:
        'Invite family, friends, and teammates to shared projects and accept invitations directly in AX.',
    publishedAt: '2026-10-07T00:00:00Z',
    dateDisplay: 'Oct 7',
  ),
  AxProductUpdate(
    id: 'update-continuity',
    title: 'Conversation Continuity',
    summary:
        'Switch Workers while keeping your Workstream conversation in context without losing turn history.',
    publishedAt: '2026-10-06T00:00:00Z',
    dateDisplay: 'Oct 6',
  ),
  AxProductUpdate(
    id: 'update-profiles',
    title: 'Tool Profiles',
    summary:
        'Workers now load provider capabilities dynamically from signed Tool Profiles with strict credential isolation.',
    publishedAt: '2026-10-04T00:00:00Z',
    dateDisplay: 'Oct 4',
  ),
];

const _defaultAiUpdates = [
  AxAiUpdate(
    id: 'ai-chatgpt-models',
    workerTypeId: 'chatgpt',
    workerDisplayName: 'ChatGPT Worker',
    title: 'Supported model catalog updated',
    detail:
        'Auto model and latest reasoning models are selectable for your requests.',
  ),
  AxAiUpdate(
    id: 'ai-gemini-models',
    workerTypeId: 'gemini',
    workerDisplayName: 'Gemini Worker',
    title: 'Multi-modal search & tools',
    detail:
        'Gemini Worker supports grounded web search and structured outputs.',
  ),
];
