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
    this.productUpdateReadStates = const {},
    this.aiUpdates = const [],
    this.onAcceptInvitation,
    this.onDeclineInvitation,
    this.onOpenWorkstream,
    this.onOpenNotifications,
    this.onOpenWhatsNew,
    this.onOpenUpdateDetail,
    this.onDismissUpdate,
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
  final Map<String, AxUserProductUpdateState> productUpdateReadStates;
  final List<AxAiUpdate> aiUpdates;
  final ValueChanged<AxProjectInvitation>? onAcceptInvitation;
  final ValueChanged<AxProjectInvitation>? onDeclineInvitation;
  final void Function(String projectId, String workstreamId)? onOpenWorkstream;
  final VoidCallback? onOpenNotifications;
  final VoidCallback? onOpenWhatsNew;
  final ValueChanged<AxProductUpdate>? onOpenUpdateDetail;
  final ValueChanged<AxProductUpdate>? onDismissUpdate;

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
          productUpdateReadStates: productUpdateReadStates,
          aiUpdates: aiUpdates,
          onAcceptInvitation: onAcceptInvitation,
          onDeclineInvitation: onDeclineInvitation,
          run: run,
          openFindingCount: openFindingCount,
          onOpenWorkspaces: onOpenWorkspaces,
          onOpenProject: onOpenProject,
          onOpenRun: onOpenRun,
          onOpenWorkstream: onOpenWorkstream,
          onOpenNotifications: onOpenNotifications,
          onOpenWhatsNew: onOpenWhatsNew,
          onOpenUpdateDetail: onOpenUpdateDetail,
          onDismissUpdate: onDismissUpdate,
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
    this.invitations = const [],
    this.attentionItems = const [],
    this.continueWorkItems = const [],
    this.productUpdates = const [],
    this.productUpdateReadStates = const {},
    this.aiUpdates = const [],
    this.onAcceptInvitation,
    this.onDeclineInvitation,
    required this.run,
    required this.openFindingCount,
    required this.onOpenWorkspaces,
    required this.onOpenProject,
    required this.onOpenRun,
    this.onOpenWorkstream,
    this.onOpenNotifications,
    this.onOpenWhatsNew,
    this.onOpenUpdateDetail,
    this.onDismissUpdate,
  });

  final List<AxProject> projects;
  final List<AxWorkspace> workspaces;
  final List<AxWorker> workers;
  final List<AxProjectInvitation> invitations;
  final List<AxHomeAttentionItem> attentionItems;
  final List<AxContinueWorkItem> continueWorkItems;
  final List<AxProductUpdate> productUpdates;
  final Map<String, AxUserProductUpdateState> productUpdateReadStates;
  final List<AxAiUpdate> aiUpdates;
  final ValueChanged<AxProjectInvitation>? onAcceptInvitation;
  final ValueChanged<AxProjectInvitation>? onDeclineInvitation;
  final AxRun? run;
  final int openFindingCount;
  final VoidCallback onOpenWorkspaces;
  final ValueChanged<String> onOpenProject;
  final void Function(String projectId, String runId) onOpenRun;
  final void Function(String projectId, String workstreamId)? onOpenWorkstream;
  final VoidCallback? onOpenNotifications;
  final VoidCallback? onOpenWhatsNew;
  final ValueChanged<AxProductUpdate>? onOpenUpdateDetail;
  final ValueChanged<AxProductUpdate>? onDismissUpdate;

  List<AxProductUpdate> get _effectiveProductUpdates =>
      AxProductUpdateService.getHomeUpdates(
        productUpdates.isNotEmpty ? productUpdates : defaultProductUpdates,
        readStates: productUpdateReadStates,
        limit: 3,
      );

  int get _unreadWhatsNewCount => AxProductUpdateService.computeUnreadCount(
        productUpdates.isNotEmpty ? productUpdates : defaultProductUpdates,
        readStates: productUpdateReadStates,
      );

  List<AxAiCapabilityUpdate> get _effectiveAiUpdates =>
      AxAiCapabilityUpdateService.getRelevantUpdates(
        updates: aiUpdates.isNotEmpty ? aiUpdates : defaultAiCapabilityUpdates,
        workers: workers,
        projects: projects,
      );

  List<AxContinueWorkItem> _deriveDefaultContinueWorkItems(
      List<AxProject> projects) {
    final list = <AxContinueWorkItem>[];
    for (final p in projects) {
      if (p.archived) continue;
      if (p.workstreams.isNotEmpty) {
        for (final ws in p.workstreams) {
          if (ws.archived) continue;
          list.add(AxContinueWorkItem(
            projectId: p.id,
            projectName: p.name,
            workstreamId: ws.id,
            workstreamTitle: ws.name,
            collaboratorsDisplay: ws.lead.isNotEmpty && ws.lead != 'Unassigned'
                ? ws.lead
                : 'You and team AI',
            lastMessageSnippet: ws.brief.isNotEmpty
                ? ws.brief
                : 'Continue conversation and work in context',
            lastActivityDisplay:
                p.lastActivity.isNotEmpty ? p.lastActivity : 'Recently',
          ));
        }
      } else {
        list.add(AxContinueWorkItem(
          projectId: p.id,
          projectName: p.name,
          workstreamId: 'default',
          workstreamTitle: 'Main Workstream',
          collaboratorsDisplay: 'You and team AI',
          lastMessageSnippet: 'Continue conversation and work in context',
          lastActivityDisplay:
              p.lastActivity.isNotEmpty ? p.lastActivity : 'Recently',
        ));
      }
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
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

          // 1. FOR YOU (Actionable Items requiring attention: invitations, inputs, failed runs, worker/workspace problems, completed work)
          _ForYouSection(
            invitations: invitations,
            attentionItems: attentionItems,
            openFindingCount: openFindingCount,
            projects: projects,
            onAcceptInvitation: onAcceptInvitation,
            onDeclineInvitation: onDeclineInvitation,
            onOpenProject: onOpenProject,
            onOpenWorkstream: onOpenWorkstream,
            onOpenWorkspaces: onOpenWorkspaces,
            onOpenNotifications: onOpenNotifications,
          ),

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

          // 2. CONTINUE WORKING (Recent relevant Workstreams, 3-5 items)
          if (hasContinueWork) ...[
            const _SectionHeader(title: 'Continue working'),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth > 700;
                final items = AxRecentWorkRanker.rank(
                  continueWorkItems.isNotEmpty
                      ? continueWorkItems
                      : _deriveDefaultContinueWorkItems(projects),
                  limit: 5,
                );

                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: isWide ? 2 : 1,
                    mainAxisExtent: isWide ? 195 : 205,
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
          if (_effectiveProductUpdates.isNotEmpty) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Text(
                      "What's new",
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                    if (_unreadWhatsNewCount > 0) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$_unreadWhatsNewCount',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                TextButton(
                  onPressed: onOpenWhatsNew ??
                      () => AxWhatsNewDialog.show(
                            context,
                            updates: productUpdates.isNotEmpty
                                ? productUpdates
                                : defaultProductUpdates,
                            readStates: productUpdateReadStates,
                            onOpenUpdateDetail: onOpenUpdateDetail,
                            onDismissUpdate: onDismissUpdate,
                          ),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('See all'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    for (var i = 0;
                        i < _effectiveProductUpdates.length;
                        i++) ...[
                      _ProductUpdateTile(
                        update: _effectiveProductUpdates[i],
                        onTap: () {
                          if (onOpenUpdateDetail != null) {
                            onOpenUpdateDetail!(_effectiveProductUpdates[i]);
                          } else {
                            AxWhatsNewDialog.show(
                              context,
                              updates: productUpdates.isNotEmpty
                                  ? productUpdates
                                  : defaultProductUpdates,
                              readStates: productUpdateReadStates,
                              initialUpdateId: _effectiveProductUpdates[i].id,
                              onOpenUpdateDetail: onOpenUpdateDetail,
                              onDismissUpdate: onDismissUpdate,
                            );
                          }
                        },
                      ),
                      if (i < _effectiveProductUpdates.length - 1)
                        const Divider(height: 1),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 28),
          ],

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
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
    );
  }
}

class AxHomeAttentionProjector {
  static List<AxHomeAttentionItem> project({
    required List<AxProjectInvitation> invitations,
    required List<AxHomeAttentionItem> rawAttentionItems,
    required int openFindingCount,
    required List<AxProject> projects,
    ValueChanged<AxProjectInvitation>? onAcceptInvitation,
    ValueChanged<AxProjectInvitation>? onDeclineInvitation,
    ValueChanged<String>? onOpenProject,
    void Function(String projectId, String workstreamId)? onOpenWorkstream,
    VoidCallback? onOpenWorkspaces,
  }) {
    final list = <AxHomeAttentionItem>[];

    // 1. Invitations
    for (final inv in invitations) {
      final inviter = inv.invitedByUserName.isNotEmpty
          ? inv.invitedByUserName
          : (inv.invitedByUserEmail.isNotEmpty
              ? inv.invitedByUserEmail
              : 'A collaborator');
      list.add(AxHomeAttentionItem(
        id: 'invite-${inv.id}',
        type: AxHomeAttentionType.projectInvitation,
        kind: AxHomeAttentionType.projectInvitation,
        categoryLabel: 'Project invitation',
        title: '$inviter invited you to ${inv.projectName}',
        description:
            '${inv.role.toUpperCase()} · ${_formatRelativeTime(inv.createdAt)}',
        timestamp: DateTime.tryParse(inv.createdAt),
        timestampDisplay: _formatRelativeTime(inv.createdAt),
        invitation: inv,
        projectId: inv.projectId,
        read: false,
        isUnread: true,
        isActionable: true,
        createdAt: DateTime.tryParse(inv.createdAt),
        primaryAction: AxHomeAttentionAction(
          label: 'Accept',
          onPerform: onAcceptInvitation != null
              ? () => onAcceptInvitation(inv)
              : () {},
        ),
        secondaryAction: AxHomeAttentionAction(
          label: 'Decline',
          onPerform: onDeclineInvitation != null
              ? () => onDeclineInvitation(inv)
              : () {},
          isDestructive: true,
        ),
      ));
    }

    // 2. Attention items (derive action closures if not already set)
    for (final raw in rawAttentionItems) {
      AxHomeAttentionAction? primary = raw.primaryAction;
      final secondary = raw.secondaryAction;

      if (primary == null &&
          raw.actionLabel != null &&
          raw.actionLabel!.isNotEmpty) {
        final label = raw.actionLabel!;
        VoidCallback action = () {};
        if (raw.effectiveType == AxHomeAttentionType.workspaceProblem) {
          if (onOpenWorkspaces != null) {
            action = onOpenWorkspaces;
          }
        } else if (raw.projectId != null &&
            raw.workstreamId != null &&
            onOpenWorkstream != null) {
          action = () => onOpenWorkstream(raw.projectId!, raw.workstreamId!);
        } else if (raw.projectId != null && onOpenProject != null) {
          action = () => onOpenProject(raw.projectId!);
        }
        primary = AxHomeAttentionAction(
          label: label,
          onPerform: action,
        );
      }

      list.add(AxHomeAttentionItem(
        id: raw.id,
        type: raw.type,
        kind: raw.kind,
        priority: raw.priority,
        title: raw.title,
        description:
            raw.description.isNotEmpty ? raw.description : raw.subtitle,
        subtitle: raw.subtitle,
        projectId: raw.projectId,
        workstreamId: raw.workstreamId,
        workerId: raw.workerId,
        workspaceId: raw.workspaceId,
        timestamp: raw.timestamp ?? raw.createdAt,
        timestampDisplay: raw.timestampDisplay,
        categoryLabel: raw.categoryLabel,
        invitation: raw.invitation,
        severity: raw.severity,
        read: raw.read,
        isUnread: raw.isUnread,
        isActionable: raw.isActionable,
        actionLabel: raw.actionLabel,
        primaryAction: primary,
        secondaryAction: secondary,
        createdAt: raw.createdAt,
      ));
    }

    // 3. Open findings
    if (openFindingCount > 0 &&
        !list.any((it) => it.effectiveType == AxHomeAttentionType.needsInput)) {
      final firstProjectId = projects.isNotEmpty ? projects.first.id : null;
      list.add(AxHomeAttentionItem(
        id: 'findings-open',
        type: AxHomeAttentionType.needsInput,
        kind: AxHomeAttentionType.needsInput,
        categoryLabel: 'Needs your input',
        title:
            '$openFindingCount open finding${openFindingCount == 1 ? '' : 's'} require review',
        description: 'Review task results and verification evidence',
        subtitle: 'Review task results and verification evidence',
        timestampDisplay: 'Needs attention',
        projectId: firstProjectId,
        read: false,
        isUnread: true,
        isActionable: true,
        actionLabel: 'Review →',
        primaryAction: AxHomeAttentionAction(
          label: 'Review →',
          onPerform: (firstProjectId != null && onOpenProject != null)
              ? () => onOpenProject(firstProjectId)
              : () {},
        ),
      ));
    }

    // Sort by: priority -> unread -> actionability -> recency
    list.sort((a, b) {
      final pA = a.priorityOrder;
      final pB = b.priorityOrder;
      if (pA != pB) return pA.compareTo(pB);

      if (a.isUnread != b.isUnread) {
        return a.isUnread ? -1 : 1;
      }

      if (a.isActionable != b.isActionable) {
        return a.isActionable ? -1 : 1;
      }

      final timeA = a.createdAt;
      final timeB = b.createdAt;
      if (timeA != null && timeB != null) {
        final recency = timeB.compareTo(timeA);
        if (recency != 0) return recency;
      } else if (timeA != null) {
        return -1;
      } else if (timeB != null) {
        return 1;
      }

      return a.id.compareTo(b.id);
    });

    return list.take(5).toList();
  }
}

class _ForYouSection extends StatelessWidget {
  const _ForYouSection({
    required this.invitations,
    required this.attentionItems,
    required this.openFindingCount,
    required this.projects,
    this.onAcceptInvitation,
    this.onDeclineInvitation,
    required this.onOpenProject,
    this.onOpenWorkstream,
    required this.onOpenWorkspaces,
    this.onOpenNotifications,
  });

  final List<AxProjectInvitation> invitations;
  final List<AxHomeAttentionItem> attentionItems;
  final int openFindingCount;
  final List<AxProject> projects;
  final ValueChanged<AxProjectInvitation>? onAcceptInvitation;
  final ValueChanged<AxProjectInvitation>? onDeclineInvitation;
  final ValueChanged<String> onOpenProject;
  final void Function(String projectId, String workstreamId)? onOpenWorkstream;
  final VoidCallback onOpenWorkspaces;
  final VoidCallback? onOpenNotifications;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final items = AxHomeAttentionProjector.project(
      invitations: invitations,
      rawAttentionItems: attentionItems,
      openFindingCount: openFindingCount,
      projects: projects,
      onAcceptInvitation: onAcceptInvitation,
      onDeclineInvitation: onDeclineInvitation,
      onOpenProject: onOpenProject,
      onOpenWorkstream: onOpenWorkstream,
      onOpenWorkspaces: onOpenWorkspaces,
    );

    if (items.isEmpty) return const SizedBox.shrink();

    final totalCount = invitations.length +
        attentionItems.length +
        (openFindingCount > 0 ? 1 : 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'For you',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                if (totalCount > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$totalCount',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (onOpenNotifications != null)
              Flexible(
                child: TextButton(
                  onPressed: onOpenNotifications,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text(
                    'View all notifications →',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            side: BorderSide(
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              for (var i = 0; i < items.length; i++) ...[
                _ForYouItemTile(item: items[i]),
                if (i < items.length - 1)
                  Divider(
                    height: 1,
                    color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _ForYouItemTile extends StatelessWidget {
  const _ForYouItemTile({
    required this.item,
  });

  final AxHomeAttentionItem item;

  String _deriveCategory() {
    if (item.categoryLabel != null && item.categoryLabel!.isNotEmpty) {
      return item.categoryLabel!;
    }
    return switch (item.effectiveType) {
      AxHomeAttentionType.projectInvitation => 'Project invitation',
      AxHomeAttentionType.needsInput => 'Needs your input',
      AxHomeAttentionType.approvalRequired => 'Approval required',
      AxHomeAttentionType.executionFailed => 'Failed execution',
      AxHomeAttentionType.workerProblem => 'Worker needs attention',
      AxHomeAttentionType.workspaceProblem => 'Workspace offline',
      AxHomeAttentionType.executionCompleted => 'Completed',
    };
  }

  Color _deriveCategoryColor(ColorScheme colorScheme, bool isDark) {
    return switch (item.effectiveType) {
      AxHomeAttentionType.projectInvitation =>
        ConclaveColors.primaryForeground(isDark),
      AxHomeAttentionType.needsInput ||
      AxHomeAttentionType.approvalRequired =>
        isDark ? Colors.orangeAccent : Colors.orange.shade800,
      AxHomeAttentionType.executionFailed => colorScheme.error,
      AxHomeAttentionType.workerProblem ||
      AxHomeAttentionType.workspaceProblem =>
        isDark ? Colors.amberAccent : Colors.amber.shade900,
      AxHomeAttentionType.executionCompleted =>
        isDark ? Colors.greenAccent : Colors.green.shade700,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final category = _deriveCategory();
    final categoryColor = _deriveCategoryColor(colorScheme, isDark);
    final hasActions =
        item.primaryAction != null || item.secondaryAction != null;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: categoryColor.withValues(alpha: isDark ? 0.2 : 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  category,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: categoryColor,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              if (item.timestampDisplay != null &&
                  item.timestampDisplay!.isNotEmpty)
                Text(
                  item.timestampDisplay!,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            item.title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (item.subtitle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              item.subtitle,
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
                height: 1.3,
              ),
            ),
          ],
          if (hasActions) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (item.secondaryAction != null) ...[
                  OutlinedButton(
                    onPressed: item.secondaryAction!.onPerform,
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                    ),
                    child: Text(item.secondaryAction!.label),
                  ),
                  if (item.primaryAction != null) const SizedBox(width: 8),
                ],
                if (item.primaryAction != null)
                  FilledButton(
                    onPressed: item.primaryAction!.onPerform,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 6),
                    ),
                    child: Text(item.primaryAction!.label),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

String _formatRelativeTime(String? raw) {
  if (raw == null || raw.isEmpty) return 'Recently';
  try {
    final dt = DateTime.parse(raw);
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} minutes ago';
    if (diff.inHours < 24) return '${diff.inHours} hours ago';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  } catch (_) {
    return raw;
  }
}

class _ContinueWorkCard extends StatelessWidget {
  const _ContinueWorkCard({required this.item, required this.onTap});

  final AxContinueWorkItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final snippetText = item.lastMessageSnippet.isNotEmpty
        ? (item.lastMessageSnippet.startsWith('"')
            ? item.lastMessageSnippet
            : '"${item.lastMessageSnippet}"')
        : '';

    final contextMeta = item.collaboratorsDisplay.isNotEmpty &&
            item.lastActivityDisplay.isNotEmpty
        ? '${item.collaboratorsDisplay} · ${item.lastActivityDisplay}'
        : (item.collaboratorsDisplay.isNotEmpty
            ? item.collaboratorsDisplay
            : item.lastActivityDisplay);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 1. PROJECT NAME (uppercase, tracked label)
                  Text(
                    item.projectName.toUpperCase(),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      letterSpacing: 0.5,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  // 2. WORKSTREAM TITLE
                  Text(
                    item.workstreamTitle,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  // 3. Collaborators + Time (e.g., ChatGPT · 23 min ago)
                  if (contextMeta.isNotEmpty)
                    Text(
                      contextMeta,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: ConclaveColors.primaryForeground(isDark),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (snippetText.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    // 4. "We should persist the..." snippet
                    Text(
                      snippetText,
                      style: TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        color: colorScheme.onSurfaceVariant,
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              // 5. Action: Continue →
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton.tonal(
                    onPressed: onTap,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 4),
                    ),
                    child: const Text('Continue →'),
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
  const _ProductUpdateTile({
    required this.update,
    this.onTap,
  });

  final AxProductUpdate update;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          update.category.label.toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        update.dateDisplay,
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    update.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    update.summary,
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: onTap,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              ),
              child: const Text('Learn more →'),
            ),
          ],
        ),
      ),
    );
  }
}

class AxWhatsNewDialog extends StatelessWidget {
  const AxWhatsNewDialog({
    super.key,
    required this.updates,
    this.readStates = const {},
    this.initialUpdateId,
    this.onOpenUpdateDetail,
    this.onDismissUpdate,
  });

  final List<AxProductUpdate> updates;
  final Map<String, AxUserProductUpdateState> readStates;
  final String? initialUpdateId;
  final ValueChanged<AxProductUpdate>? onOpenUpdateDetail;
  final ValueChanged<AxProductUpdate>? onDismissUpdate;

  static Future<void> show(
    BuildContext context, {
    required List<AxProductUpdate> updates,
    Map<String, AxUserProductUpdateState> readStates = const {},
    String? initialUpdateId,
    ValueChanged<AxProductUpdate>? onOpenUpdateDetail,
    ValueChanged<AxProductUpdate>? onDismissUpdate,
  }) {
    return showDialog<void>(
      context: context,
      builder: (context) => AxWhatsNewDialog(
        updates: updates,
        readStates: readStates,
        initialUpdateId: initialUpdateId,
        onOpenUpdateDetail: onOpenUpdateDetail,
        onDismissUpdate: onDismissUpdate,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final grouped = AxProductUpdateService.groupUpdatesByMonthYear(updates);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "What's New",
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Conclave changelog and product updates',
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Expanded(
                child: grouped.isEmpty
                    ? Center(
                        child: Text(
                          'No product updates available.',
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: grouped.keys.length,
                        itemBuilder: (context, groupIndex) {
                          final monthYear = grouped.keys.elementAt(groupIndex);
                          final items = grouped[monthYear]!;

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 10),
                                  child: Text(
                                    monthYear,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: colorScheme.primary,
                                    ),
                                  ),
                                ),
                                for (final update in items) ...[
                                  Card(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Row(
                                                children: [
                                                  Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 6,
                                                        vertical: 2),
                                                    decoration: BoxDecoration(
                                                      color: colorScheme
                                                          .surfaceContainerHighest,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              4),
                                                    ),
                                                    child: Text(
                                                      update.category.label
                                                          .toUpperCase(),
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        letterSpacing: 0.5,
                                                        color: colorScheme
                                                            .onSurfaceVariant,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Text(
                                                    update.dateDisplay,
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: colorScheme
                                                          .onSurfaceVariant,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              if (onDismissUpdate != null)
                                                IconButton(
                                                  icon: const Icon(
                                                    Icons
                                                        .visibility_off_outlined,
                                                    size: 18,
                                                  ),
                                                  tooltip: 'Hide update',
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  onPressed: () =>
                                                      onDismissUpdate!(update),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          Text(
                                            update.title,
                                            style: const TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            update.summary,
                                            style: TextStyle(
                                              fontSize: 13,
                                              color:
                                                  colorScheme.onSurfaceVariant,
                                              height: 1.4,
                                            ),
                                          ),
                                          if (update.details != null &&
                                              update.details!.isNotEmpty) ...[
                                            const SizedBox(height: 10),
                                            Container(
                                              padding: const EdgeInsets.all(10),
                                              decoration: BoxDecoration(
                                                color: colorScheme
                                                    .surfaceContainerLow,
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              child: Text(
                                                update.details!,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: colorScheme.onSurface,
                                                  height: 1.35,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const defaultProductUpdates = [
  AxProductUpdate(
    id: 'update-invitations',
    slug: 'project-invitations',
    title: 'Project Invitations',
    summary:
        'Invite family, friends, and teammates to shared projects and accept invitations directly in AX.',
    details:
        'Project owners and editors can now invite collaborators via email or handle invitation approvals directly within Conclave AX with full role-based access control.',
    category: AxProductUpdateCategory.collaboration,
    publishedAt: '2026-10-07T00:00:00Z',
    dateDisplay: 'Oct 7',
    status: AxProductUpdateStatus.published,
  ),
  AxProductUpdate(
    id: 'update-continuity',
    slug: 'conversation-continuity',
    title: 'Conversation Continuity',
    summary:
        'Switch Workers while keeping your Workstream conversation in context without losing turn history.',
    details:
        'Transition seamlessly between ChatGPT, Claude, and Gemini workers across conversational turns with preserved contextual memory and synthesis state.',
    category: AxProductUpdateCategory.workflow,
    publishedAt: '2026-10-06T00:00:00Z',
    dateDisplay: 'Oct 6',
    status: AxProductUpdateStatus.published,
  ),
  AxProductUpdate(
    id: 'update-profiles',
    slug: 'tool-profiles',
    title: 'Tool Profiles',
    summary:
        'Workers now load provider capabilities dynamically from signed Tool Profiles with strict credential isolation.',
    details:
        'Signed cryptographic tool profiles define explicit capabilities, CLI execution constraints, and isolate local model credentials from cloud telemetry.',
    category: AxProductUpdateCategory.security,
    publishedAt: '2026-10-04T00:00:00Z',
    dateDisplay: 'Oct 4',
    status: AxProductUpdateStatus.published,
  ),
  AxProductUpdate(
    id: 'update-workspace-sync',
    slug: 'workspace-local-sync',
    title: 'Workspace Local Sync',
    summary:
        'Seamless bidirectional file synchronization and live process execution on your local machine.',
    details:
        'Connect your Mac, Linux, or Windows machine as a local execution workspace with isolated work roots and real-time execution telemetry.',
    category: AxProductUpdateCategory.workspace,
    publishedAt: '2026-09-28T00:00:00Z',
    dateDisplay: 'Sep 28',
    status: AxProductUpdateStatus.published,
  ),
];

class _AiUpdateCard extends StatelessWidget {
  const _AiUpdateCard({
    required this.update,
  });

  final AxAiCapabilityUpdate update;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                _aiDot(update.workerProfileId),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    update.workerDisplayName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    update.type.label.toUpperCase(),
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  update.dateDisplay,
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              update.title,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              update.summary,
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
                height: 1.3,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _aiDot(String typeId) {
    final color = switch (typeId.toLowerCase()) {
      'chatgpt' => const Color(0xFF10A37F),
      'gemini' => const Color(0xFF3B82F6),
      'claude' => const Color(0xFFD97706),
      'ollama' => const Color(0xFF6366F1),
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

const defaultAiCapabilityUpdates = [
  AxAiCapabilityUpdate(
    id: 'ai-chatgpt-models',
    workerProfileId: 'chatgpt',
    provider: 'openai',
    type: AxAiCapabilityUpdateType.modelAdded,
    modelId: 'gpt-4o',
    modelDisplayName: 'GPT-4o & Reasoning',
    title: 'Supported model catalog updated',
    summary:
        'Auto model and latest reasoning models are selectable for your requests.',
    publishedAt: '2026-10-07T00:00:00Z',
    dateDisplay: 'Oct 7',
  ),
  AxAiCapabilityUpdate(
    id: 'ai-gemini-models',
    workerProfileId: 'gemini',
    provider: 'google',
    type: AxAiCapabilityUpdateType.capabilityAdded,
    title: 'Multi-modal search & tools',
    summary:
        'Gemini Worker supports grounded web search and structured outputs.',
    publishedAt: '2026-10-05T00:00:00Z',
    dateDisplay: 'Oct 5',
  ),
  AxAiCapabilityUpdate(
    id: 'ai-claude-artifacts',
    workerProfileId: 'claude',
    provider: 'anthropic',
    type: AxAiCapabilityUpdateType.capabilityChanged,
    title: 'Interactive artifact synthesis',
    summary:
        'Claude Worker streams interactive artifacts and code snippets directly.',
    publishedAt: '2026-10-02T00:00:00Z',
    dateDisplay: 'Oct 2',
  ),
];
