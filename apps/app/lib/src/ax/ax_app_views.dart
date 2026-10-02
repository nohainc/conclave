part of 'ax_app.dart';

extension _AxAppViews on _AxAppState {
  Widget _runDetailsView(bool compact) {
    switch (navigation.kind) {
      case AxRouteKind.workspaces:
        return _workspacesView();
      case AxRouteKind.profileSecurity:
        return _profileSecurityView();
      case AxRouteKind.projects:
        return _homeView();
      case AxRouteKind.project:
        return _projectOverviewView();
      case AxRouteKind.workstream:
        return _workstreamView();
      case AxRouteKind.search:
        return _searchView();
      case AxRouteKind.run:
      case AxRouteKind.home:
      case AxRouteKind.login:
      case AxRouteKind.desktopAuthApproval:
        break;
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(
        spacing: 16,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(selectedProject?.name ?? 'Project',
                style: const TextStyle(color: Color(0xff777683), fontSize: 12)),
            const SizedBox(height: 7),
            const Text('Run details',
                style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                    color: Color(0xff20202c),
                    letterSpacing: -.5)),
            const SizedBox(height: 5),
            const Text(
                'Follow execution, results, verification, and diagnostics.',
                style: TextStyle(color: Color(0xff777683), fontSize: 13)),
          ]),
        ],
      ),
      const SizedBox(height: 20),
      _runSection(
        title: 'Overview',
        subtitle: 'Status, elapsed work, Engine, Profile, and findings',
        icon: Icons.dashboard_outlined,
        child: Column(children: [
          _runHeader(compact),
          const SizedBox(height: 16),
          _runContextCard(),
          const SizedBox(height: 16),
        ]),
      ),
      const SizedBox(height: 16),
      _runSection(
        title: 'Workspaces',
        subtitle: 'Task DAG, progress, and active Worker details',
        icon: Icons.account_tree_outlined,
        child: compact
            ? Column(children: [
                _executionCard(),
                const SizedBox(height: 16),
                _taskDetailsCard(),
              ])
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 6, child: _executionCard()),
                const SizedBox(width: 16),
                Expanded(flex: 4, child: _taskDetailsCard()),
              ]),
      ),
      const SizedBox(height: 16),
      _runSection(
        title: 'Results',
        subtitle: 'Candidate answers, synthesis, and artifacts',
        icon: Icons.auto_awesome_outlined,
        child: _resultsDetailsCard(),
      ),
      const SizedBox(height: 16),
      _runSection(
        title: 'Verification',
        subtitle: 'Tests, findings, and completion criteria',
        icon: Icons.verified_outlined,
        child: _evidenceCard(),
      ),
      const SizedBox(height: 16),
      _runSection(
        title: 'Technical',
        subtitle: 'Events, model calls, correlation IDs, and diagnostics',
        icon: Icons.code_outlined,
        initiallyExpanded: false,
        child: Column(children: [
          _technicalDetailsCard(),
          const SizedBox(height: 16),
          _timelineCard(),
        ]),
      ),
    ]);
  }

  Widget _runSection({
    required String title,
    required String subtitle,
    required IconData icon,
    required Widget child,
    bool initiallyExpanded = true,
  }) =>
      Card(
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          leading: Icon(icon, color: const Color(0xff6254d9)),
          title: Text(title,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          subtitle: Text(subtitle),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          children: [child],
        ),
      );

  Color _runStatusColor(RunStatus status) => switch (status) {
        RunStatus.completed => const Color(0xff43b17f),
        RunStatus.failed || RunStatus.cancelled => const Color(0xffbd6565),
        RunStatus.paused || RunStatus.waiting => const Color(0xffedb84d),
        _ => const Color(0xff6254d9),
      };

  String _statusLabel(RunStatus status) =>
      status.name[0].toUpperCase() + status.name.substring(1);

  Future<void> _controlRun(String command) async {
    final runId = snapshot.run?.id ?? snapshot.activeRunId;
    if (runId == null) return;
    try {
      await store.runs.control(runId, command);
      if (!mounted) return;
      setState(() {
        optimisticRunStatus = switch (command) {
          'pause' => RunStatus.paused,
          'resume' => RunStatus.running,
          'cancel' => RunStatus.cancelled,
          _ => optimisticRunStatus,
        };
      });
    } catch (error) {
      if (mounted) setState(() => loadError = error.toString());
    }
  }

  Widget _runHeader(bool compact) {
    final run = snapshot.run;
    final status = optimisticRunStatus ?? run?.status ?? RunStatus.completed;
    final canControl = run != null &&
        {
          RunStatus.active,
          RunStatus.running,
          RunStatus.waiting,
          RunStatus.paused
        }.contains(status);
    final paused = status == RunStatus.paused;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(18),
            child: Wrap(
                spacing: 18,
                runSpacing: 15,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Icon(Icons.bolt_rounded,
                      color: Color(0xff6254d9), size: 24),
                  Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            run?.objective ??
                                'No work request has been started',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14)),
                        const SizedBox(height: 4),
                        Text(
                            run == null
                                ? 'Select New work request to begin'
                                : 'Work Request ${run.id}',
                            style: const TextStyle(
                                color: Color(0xff898896), fontSize: 11))
                      ]),
                  _statusChip(_statusLabel(status), _runStatusColor(status)),
                  const SizedBox(width: 5),
                  if (!compact)
                    Text(
                        '${run?.verifiedCriterionCount ?? 0} / ${run?.criterionCount ?? 0} criteria verified',
                        style: const TextStyle(
                            color: Color(0xff777683), fontSize: 11)),
                  OutlinedButton.icon(
                      onPressed: canControl
                          ? () => _controlRun(paused ? 'resume' : 'pause')
                          : null,
                      icon: Icon(
                          paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          size: 16),
                      label: Text(paused ? 'Resume' : 'Pause'),
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9))),
                  OutlinedButton.icon(
                      onPressed:
                          canControl ? () => _controlRun('cancel') : null,
                      icon: const Icon(Icons.close_rounded, size: 16),
                      label: const Text('Cancel'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xffa45555),
                          side: const BorderSide(color: Color(0xffefd5d5)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9))),
                ])));
  }

  Widget _executionCard() {
    final run = snapshot.run;
    if (snapshot.tasks.isEmpty) {
      return _panel(
        title: 'Execution tree',
        subtitle: 'Live run state',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(run == null
              ? 'No active run for this project.'
              : 'The run has not created tasks yet.'),
        ),
      );
    }
    final completed = snapshot.tasks
        .where((task) => task.status == TaskStatus.completed)
        .length;
    return _panel(
        title: 'Execution tree',
        subtitle: 'Live run state',
        trailing: _statusChip('$completed / ${snapshot.tasks.length} tasks',
            const Color(0xff6254d9)),
        child: Column(children: [
          TaskPipelineDAG(
            tasks: snapshot.tasks,
            selectedTaskId: selectedTaskId,
            onSelectTask: (taskId) => setState(() => selectedTaskId = taskId),
          ),
          ...snapshot.tasks.map(_taskRow),
        ]));
  }

  Widget _runContextCard() {
    final task = selectedTask ?? snapshot.tasks.firstOrNull;
    final worker = task?.worker.isNotEmpty == true ? task!.worker : 'Auto';
    return _panel(
      title: 'Execution context',
      subtitle: 'Trusted assignment details',
      child: Wrap(
        spacing: 24,
        runSpacing: 12,
        children: [
          _contextLine(Icons.extension_outlined, 'Worker', worker),
          _contextLine(Icons.extension_outlined, 'Worker connection', 'Auto'),
          _contextLine(Icons.computer_outlined, 'Workspace', 'Auto'),
          _contextLine(Icons.smart_toy_outlined, 'Model', 'Auto'),
        ],
      ),
    );
  }

  Widget _contextLine(IconData icon, String label, String value) => SizedBox(
        width: 190,
        child: Row(children: [
          Icon(icon, size: 16, color: const Color(0xff9997a3)),
          const SizedBox(width: 8),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style:
                      const TextStyle(color: Color(0xff9997a3), fontSize: 10)),
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          ),
        ]),
      );

  Widget _resultsDetailsCard() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _candidateOutputsCard(),
          const SizedBox(height: 16),
          _panel(
            title: 'Artifacts and changes',
            subtitle: '${snapshot.artifacts.length} stored result artifacts',
            child: snapshot.artifacts.isEmpty
                ? const Text(
                    'Artifacts will appear here as the Run produces results.')
                : Column(
                    children: snapshot.artifacts
                        .map((artifact) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.description_outlined),
                              title: Text(artifact.name),
                              subtitle:
                                  Text('${artifact.type} · ${artifact.size}'),
                              trailing: Text(artifact.source),
                            ))
                        .toList(),
                  ),
          ),
        ],
      );

  Widget _technicalDetailsCard() => _panel(
        title: 'Technical context',
        subtitle: 'Read-only execution diagnostics',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (snapshot.events.isEmpty)
              const Text('Diagnostics will appear as Workers execute.')
            else
              Text(
                  'Correlation IDs: ${snapshot.events.where((event) => event.correlationId != null).map((event) => event.correlationId).toSet().join(', ')}',
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xff777683))),
          ],
        ),
      );

  Widget _candidateOutputsCard() {
    final outputs = snapshot.candidateOutputs;
    final decision = snapshot.synthesisDecision;
    if (outputs.isEmpty && decision == null) {
      return _panel(
        title: 'Candidate outputs',
        subtitle: 'Read-only multi-worker synthesis',
        child: const Text('No candidate outputs are available.'),
      );
    }
    return _panel(
      title: 'Candidate outputs',
      subtitle: '${outputs.length} independent results',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...outputs.map(
            (output) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xfffafaff),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: const Color(0xffe6e3f8)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.account_tree_outlined,
                      size: 18, color: Color(0xff6254d9)),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${output.worker} · ${output.role}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 12)),
                        const SizedBox(height: 4),
                        Text(output.summary,
                            style: const TextStyle(
                                color: Color(0xff777683), fontSize: 11)),
                      ],
                    ),
                  ),
                  _statusChip(output.status, const Color(0xff43b17f)),
                ],
              ),
            ),
          ),
          if (decision != null) ...[
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Icons.auto_awesome,
                  color: Color(0xff6254d9), size: 18),
              const SizedBox(width: 8),
              const Text('Synthesis decision',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
              const Spacer(),
              _statusChip(decision.status, const Color(0xff43b17f)),
            ]),
            const SizedBox(height: 6),
            Text(decision.summary,
                style: const TextStyle(color: Color(0xff777683), fontSize: 11)),
            const SizedBox(height: 4),
            Text('${decision.worker} · ${decision.evidence}',
                style: const TextStyle(color: Color(0xff9a98a3), fontSize: 10)),
          ],
        ],
      ),
    );
  }

  Widget _taskRow(AxTask task, {bool selected = false}) {
    final active = selectedTaskId == task.id;
    final color = task.status == TaskStatus.completed
        ? const Color(0xff43b17f)
        : task.status.isFailed
            ? const Color(0xffb64b4b)
            : task.status == TaskStatus.running
                ? const Color(0xff6254d9)
                : const Color(0xffaaa8b2);
    return InkWell(
        onTap: () => setState(() => selectedTaskId = task.id),
        borderRadius: BorderRadius.circular(9),
        child: Container(
            margin: const EdgeInsets.only(bottom: 5),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: active ? const Color(0xfff3f1ff) : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                    color:
                        active ? const Color(0xffdcd7ff) : Colors.transparent)),
            child: Row(children: [
              Icon(
                  task.status == TaskStatus.completed
                      ? Icons.check_circle_rounded
                      : task.status.isFailed
                          ? Icons.error_rounded
                          : task.status == TaskStatus.running
                              ? Icons.timelapse_rounded
                              : Icons.radio_button_unchecked,
                  size: 17,
                  color: color),
              const SizedBox(width: 9),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(task.title,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text('${task.worker}  ·  ${task.status.name}',
                        style: const TextStyle(
                            fontSize: 10, color: Color(0xff95939e)))
                  ])),
              if (task.status == TaskStatus.running)
                SizedBox(
                    width: 45,
                    child: LinearProgressIndicator(
                        value: task.progress,
                        minHeight: 5,
                        borderRadius: BorderRadius.circular(4),
                        color: const Color(0xff7467e4),
                        backgroundColor: const Color(0xffe3e0f7))),
              const SizedBox(width: 5),
              const Icon(Icons.chevron_right_rounded,
                  size: 17, color: Color(0xffb5b3bd))
            ])));
  }

  Widget _taskDetailsCard() {
    final task = selectedTask ?? snapshot.tasks.firstOrNull;
    if (task == null) {
      return _panel(
        title: 'Task details',
        subtitle: 'No task selected',
        child: const Text('Tasks will appear here when a run begins.'),
      );
    }
    return _panel(
        title: 'Task details',
        subtitle: task.id.toUpperCase(),
        trailing: _statusChip(
            task.status.name,
            task.status == TaskStatus.running
                ? const Color(0xff6254d9)
                : const Color(0xff43b17f)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(task.title,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(height: 8),
          Text(task.detail,
              style: const TextStyle(
                  color: Color(0xff777683), fontSize: 12, height: 1.45)),
          if (task.errorCode != null) ...[
            const SizedBox(height: 8),
            Text(task.errorMessage ?? 'The assignment could not be completed.',
                key: const ValueKey('task-execution-error-message'),
                style: const TextStyle(
                    color: Color(0xff9a3d3d),
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text('Error code: ${task.errorCode}',
                key: const ValueKey('task-execution-error-code'),
                style: const TextStyle(
                    color: Color(0xff9a3d3d),
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 18),
          _detailLine(Icons.person_outline, 'Worker', task.worker),
          _detailLine(
              Icons.account_tree_outlined,
              'Dependencies',
              task.dependencies.isEmpty
                  ? 'None'
                  : task.dependencies.join(', ')),
          if (task.detail.contains('diff') ||
              task.detail.contains('@@') ||
              task.detail.startsWith('---') ||
              task.detail.startsWith('+++')) ...[
            const SizedBox(height: 16),
            const Text('Generated Artifact / Diff',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 8),
            DiffViewer(filePath: task.title, diffContent: task.detail),
          ],
          const SizedBox(height: 15),
          if (task.status == TaskStatus.running)
            FilledButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Retry task'),
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xffefedf9),
                    foregroundColor: const Color(0xff5549be),
                    elevation: 0))
        ]));
  }

  Widget _detailLine(IconData icon, String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 11),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: const Color(0xff9997a3)),
        const SizedBox(width: 9),
        SizedBox(
            width: 82,
            child: Text(label,
                style:
                    const TextStyle(color: Color(0xff9997a3), fontSize: 11))),
        Expanded(
            child: Text(value,
                style: const TextStyle(
                    color: Color(0xff454450),
                    fontSize: 11,
                    fontWeight: FontWeight.w600)))
      ]));

  Widget _timelineCard() => _panel(
        title: 'Run timeline',
        subtitle: 'Ordered events',
        trailing: TextButton(
            onPressed: _copyRunDiagnostics,
            child: const Text('Export diagnostics')),
        child: Column(
          children: snapshot.events
              .map(
                (event) => Padding(
                  padding: const EdgeInsets.only(bottom: 15),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                          width: 42,
                          child: Text(event.time,
                              style: const TextStyle(
                                  fontSize: 11, color: Color(0xffaaa8b1)))),
                      Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(top: 3, right: 11),
                          decoration: const BoxDecoration(
                              color: Color(0xff786be4),
                              shape: BoxShape.circle)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(event.title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 12)),
                            const SizedBox(height: 3),
                            Text(event.detail,
                                style: const TextStyle(
                                    color: Color(0xff898792), fontSize: 11)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      );

  Widget _evidenceCard() => _panel(
      title: 'Evidence & findings',
      subtitle:
          '${snapshot.findings.length} findings · ${snapshot.artifacts.length} artifacts',
      trailing: TextButton(
          onPressed: () {
            final project = selectedProject;
            final run = snapshot.run;
            if (project != null && run != null) {
              _navigateTo(AxNavigation.run(project.id, run.id));
            }
          },
          child: const Text('Open run details')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _metric('Tasks', '${snapshot.tasks.length}'),
          _metric('Findings', '${snapshot.findings.length}'),
          _metric('Checks',
              '${snapshot.run?.verifiedCriterionCount ?? 0} / ${snapshot.run?.criterionCount ?? 0}')
        ]),
        const SizedBox(height: 16),
        ...snapshot.findings.map((finding) => _findingRow(finding))
      ]));

  Widget _metric(String label, String value) => Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 10)),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface))
      ]));

  Widget _findingRow(AxFinding finding) => Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).colorScheme.outline)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(
            finding.status == FindingStatus.verified
                ? Icons.verified_rounded
                : Icons.warning_amber_rounded,
            size: 17,
            color: finding.status == FindingStatus.verified
                ? ConclaveBrand.success
                : ConclaveBrand.warning),
        const SizedBox(width: 8),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(finding.title,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 11)),
          const SizedBox(height: 3),
          Text('${finding.severity.name} · ${finding.status.name}',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 10))
        ]))
      ]));

  Widget _panel(
          {required String title,
          required String subtitle,
          required Widget child,
          Widget? trailing}) =>
      Builder(
        builder: (context) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final mutedColor =
              isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted;
          return Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 14)),
                            const SizedBox(height: 3),
                            Text(subtitle,
                                style:
                                    TextStyle(color: mutedColor, fontSize: 10)),
                          ],
                        ),
                      ),
                      const Spacer(),
                      if (trailing != null) trailing,
                    ],
                  ),
                  const SizedBox(height: 15),
                  child,
                ],
              ),
            ),
          );
        },
      );

  Widget _statusChip(String label, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .11),
          borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                color: color, fontSize: 10, fontWeight: FontWeight.w700))
      ]));

  List<AxWorkspace> _workspaceCards() =>
      store.workspaces.items.map((workspace) {
        final inventoryCount = workspaceWorkers
            .where((worker) =>
                worker.workspaceId == workspace.id &&
                worker.status != 'removed')
            .length;
        return workspace.copyWith(
          workerCount: workspaceWorkerInventoryLoaded
              ? inventoryCount
              : workspace.workerCount,
          projectGrantCount: workspaceProjectGrantCounts[workspace.id] ?? 0,
          lastSeen: workspace.lastSeen,
        );
      }).toList(growable: false);

  Future<void> _refreshWorkspaceProjectGrantCounts() async {
    final projects = snapshot.projects;
    if (projects.isEmpty) return;
    final counts = <String, int>{};
    await Future.wait(projects.map((project) async {
      try {
        final grants = await widget.dataSource
            .loadProjectWorkspaces(projectId: project.id);
        for (final grant in grants) {
          final workspaceId = grant['workspaceId']?.toString();
          if (workspaceId != null &&
              workspaceId.isNotEmpty &&
              grant['status']?.toString() == 'active') {
            counts.update(workspaceId, (count) => count + 1, ifAbsent: () => 1);
          }
        }
      } catch (_) {
        // Some Projects may not be readable; keep counts from readable ones.
      }
    }));
    if (mounted) setState(() => workspaceProjectGrantCounts = counts);
  }

  Widget _workspacesView() => WorkspacesPage(
        workspaces: _workspaceCards(),
        workspaceWorkers: workspaceWorkers,
        initialWorkspaceId: navigation.workspaceId,
        onSelectWorkspace: (workspaceId) {
          if (workspaceId != null) {
            _navigateTo(AxNavigation.workspaces(workspaceId: workspaceId));
          } else {
            _navigateTo(const AxNavigation.workspaces());
          }
        },
        onOpenDownloads: () => browserNavigation.openExternal(
          Uri.parse(conclaveDownloadsUrl),
        ),
        onGrant: _grantWorkspace,
      );

  Widget _profileSecurityView() {
    final viewer = store.auth.viewer ?? snapshot.viewer;
    final security = accountSecurity;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: const Text('Profile & Security',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 6),
        const Text(
            'Manage your Conclave identity, login methods, sessions, and passkeys.',
            style: TextStyle(color: Color(0xff777683), fontSize: 13)),
        const SizedBox(height: 24),
        _panel(
          title: 'Profile',
          subtitle: 'Your stable Conclave identity',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: const Color(0xffeeecff),
              child: Text(_shellContext.viewerInitials,
                  style: const TextStyle(color: Color(0xff4238a0))),
            ),
            title: Text(viewer?.displayName ?? 'Conclave user'),
            subtitle: Text(viewer?.email ?? 'Email unavailable'),
          ),
        ),
        const SizedBox(height: 16),
        _panel(
          title: 'Linked login methods',
          subtitle:
              'Link another verified provider so one provider can be unavailable without locking you out.',
          child: accountSecurityLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (security?.accounts.isEmpty ?? true)
                      const Align(
                          alignment: Alignment.centerLeft,
                          child: Text('No linked methods loaded.')),
                    ...?security?.accounts.map((account) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(account.providerId == 'github'
                              ? Icons.code
                              : Icons.account_circle_outlined),
                          title: Text(_providerLabel(account.providerId)),
                          subtitle: Text('Linked account ${account.accountId}'),
                          trailing: const Icon(Icons.verified_outlined,
                              color: Color(0xff3ca879)),
                        )),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => _linkAccountProvider('github'),
                          icon: const Icon(Icons.code, size: 17),
                          label: const Text('Link GitHub'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _linkAccountProvider('google'),
                          icon: const Icon(Icons.account_circle_outlined,
                              size: 17),
                          label: const Text('Link Google'),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        _panel(
          title: 'Active sessions',
          subtitle: 'Revoke access from a device you no longer recognize.',
          child: accountSecurityLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (security?.sessions.isEmpty ?? true)
                      const Align(
                          alignment: Alignment.centerLeft,
                          child: Text('No active sessions loaded.')),
                    ...?security?.sessions.map((session) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.devices_outlined),
                          title: Text(session.userAgent ?? 'Browser session'),
                          subtitle: Text(
                              'Expires ${_formatAccountDate(session.expiresAt)}'),
                          trailing: TextButton(
                            onPressed: () => _revokeAccountSession(session),
                            child: const Text('Revoke'),
                          ),
                        )),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        _panel(
          title: 'Passkeys',
          subtitle:
              'Use a device or security key to sign in without a password.',
          child: accountSecurityLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (security?.passkeys.isEmpty ?? true)
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('No passkeys enrolled.'),
                      ),
                    ...?security?.passkeys.map((passkey) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.fingerprint),
                          title: Text(passkey.name),
                          subtitle: Text(passkey.createdAt.isEmpty
                              ? 'WebAuthn credential'
                              : 'Added ${_formatAccountDate(passkey.createdAt)}'),
                          trailing: TextButton(
                            onPressed: () => _deletePasskey(passkey),
                            child: const Text('Remove'),
                          ),
                        )),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _registerPasskey,
                        icon: const Icon(Icons.add_circle_outline),
                        label: const Text('Add passkey'),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  String _providerLabel(String provider) => switch (provider) {
        'github' => 'GitHub',
        'google' => 'Google',
        _ => provider,
      };

  String _formatAccountDate(String value) {
    if (value.isEmpty || value == '—') return 'unknown';
    return value.replaceFirst('T', ' ').replaceFirst('Z', ' UTC');
  }
}
