import 'package:flutter/material.dart';

import '../platform/platform_services.dart';
import 'studio_models.dart';

class StudioApp extends StatefulWidget {
  const StudioApp({super.key, required this.services});

  final PlatformServices services;

  @override
  State<StudioApp> createState() => _StudioAppState();
}

class _StudioAppState extends State<StudioApp> {
  final StudioSnapshot snapshot = StudioSnapshot.demo();
  late StudioProject selectedProject;
  String? selectedTaskId = 'implement';
  int navigationIndex = 0;
  bool isPaused = false;
  bool showNewGoal = false;
  bool showWorkerDrawer = false;

  StudioTask? get selectedTask =>
      snapshot.tasks.where((task) => task.id == selectedTaskId).firstOrNull;

  @override
  void initState() {
    super.initState();
    selectedProject = snapshot.projects.first;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Conclave Studio',
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      home: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 900;
          return Scaffold(
            backgroundColor: const Color(0xfff7f8fa),
            drawer: compact ? Drawer(child: _sidebar(compact: true)) : null,
            body: Row(
              children: [
                if (!compact) SizedBox(width: 248, child: _sidebar()),
                Expanded(child: _content(compact)),
              ],
            ),
          );
        },
      ),
    );
  }

  ThemeData _theme() => ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xfff7f8fa),
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff6254d9), brightness: Brightness.light),
        fontFamily: 'Arial',
        cardTheme: const CardThemeData(
            margin: EdgeInsets.zero, elevation: 0, color: Colors.white),
      );

  Widget _sidebar({bool compact = false}) {
    return Container(
      color: const Color(0xff171725),
      padding: const EdgeInsets.fromLTRB(18, 24, 14, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                    color: const Color(0xff7768ee),
                    borderRadius: BorderRadius.circular(9)),
                child: const Icon(Icons.hub_rounded,
                    color: Colors.white, size: 18)),
            const SizedBox(width: 10),
            const Text('conclave',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    letterSpacing: -.3)),
          ]),
          const SizedBox(height: 32),
          _sidebarLabel('WORKSPACE'),
          _navItem(Icons.grid_view_rounded, 'Overview', 0),
          _navItem(Icons.track_changes_rounded, 'Goals', 1, badge: '1'),
          _navItem(Icons.people_alt_outlined, 'Workers', 2),
          _navItem(Icons.folder_copy_outlined, 'Artifacts', 3),
          const SizedBox(height: 26),
          _sidebarLabel('PROJECTS'),
          ...snapshot.projects.map((project) => _projectItem(project)),
          const Spacer(),
          if (compact) _navItem(Icons.close_rounded, 'Close menu', -1),
          _navItem(Icons.settings_outlined, 'Settings', 4),
          const SizedBox(height: 6),
          const Row(children: [
            CircleAvatar(
                radius: 15,
                backgroundColor: Color(0xffd8d2ff),
                child: Text('VN',
                    style: TextStyle(
                        fontSize: 10,
                        color: Color(0xff4238a0),
                        fontWeight: FontWeight.bold))),
            SizedBox(width: 9),
            Expanded(
                child: Text('Vitalii Noha',
                    style: TextStyle(color: Colors.white70, fontSize: 12))),
            Icon(Icons.more_horiz, color: Colors.white38, size: 18),
          ]),
        ],
      ),
    );
  }

  Widget _sidebarLabel(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 0, 8),
      child: Text(text,
          style: const TextStyle(
              color: Colors.white38,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2)));

  Widget _navItem(IconData icon, String label, int index, {String? badge}) {
    final active = navigationIndex == index;
    return InkWell(
      onTap: () {
        if (index >= 0) setState(() => navigationIndex = index);
      },
      borderRadius: BorderRadius.circular(9),
      child: Container(
        margin: const EdgeInsets.only(bottom: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
            color: active ? const Color(0xff302d4b) : Colors.transparent,
            borderRadius: BorderRadius.circular(9)),
        child: Row(
          children: [
            Icon(icon,
                size: 18,
                color: active ? const Color(0xffbcb3ff) : Colors.white54),
            const SizedBox(width: 11),
            Expanded(
                child: Text(label,
                    style: TextStyle(
                        color: active ? Colors.white : Colors.white60,
                        fontSize: 13,
                        fontWeight:
                            active ? FontWeight.w600 : FontWeight.w400))),
            if (badge != null)
              Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: const Color(0xff6254d9),
                      borderRadius: BorderRadius.circular(8)),
                  child: Text(badge,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 10)))
          ],
        ),
      ),
    );
  }

  Widget _projectItem(StudioProject project) {
    final active = selectedProject.id == project.id;
    return InkWell(
      onTap: () => setState(() => selectedProject = project),
      borderRadius: BorderRadius.circular(9),
      child: Container(
        margin: const EdgeInsets.only(bottom: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
            color: active ? const Color(0xff29283c) : Colors.transparent,
            borderRadius: BorderRadius.circular(9)),
        child: Row(children: [
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  color: active ? const Color(0xff70d6a5) : Colors.white30,
                  shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(
              child: Text(project.name,
                  style: TextStyle(
                      color: active ? Colors.white : Colors.white60,
                      fontSize: 12))),
          if (project.activeGoals > 0)
            Text('${project.activeGoals}',
                style: const TextStyle(color: Color(0xffaaa4d9), fontSize: 11))
        ]),
      ),
    );
  }

  Widget _content(bool compact) {
    return Column(children: [
      _topbar(compact),
      Expanded(
          child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                  compact ? 18 : 34, 26, compact ? 18 : 34, 40),
              child: _dashboard(compact))),
    ]);
  }

  Widget _topbar(bool compact) {
    return Container(
      height: 66,
      padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 32),
      decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xffe8e8ed)))),
      child: Row(children: [
        if (compact)
          Builder(
              builder: (context) => IconButton(
                  onPressed: () => Scaffold.of(context).openDrawer(),
                  icon: const Icon(Icons.menu_rounded))),
        const Expanded(
            child: Text('Studio',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xff20202c)))),
        IconButton(
            onPressed: () {},
            icon: const Icon(Icons.notifications_none_rounded,
                size: 21, color: Color(0xff6e6e7a))),
        const SizedBox(width: 5),
        OutlinedButton.icon(
            onPressed: () =>
                setState(() => showWorkerDrawer = !showWorkerDrawer),
            icon: const Icon(Icons.circle, size: 8, color: Color(0xff55bf8f)),
            label: const Text('3 workers online'),
            style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xff565665),
                side: const BorderSide(color: Color(0xffe2e2e8)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10))),
      ]),
    );
  }

  Widget _dashboard(bool compact) {
    if (navigationIndex == 2) return _workersView();
    if (navigationIndex == 3) return _artifactsView();
    if (navigationIndex == 4) return _settingsView();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(selectedProject.name,
              style: const TextStyle(color: Color(0xff777683), fontSize: 12)),
          const SizedBox(height: 7),
          const Text('Good morning, Vitalii',
              style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                  color: Color(0xff20202c),
                  letterSpacing: -.5)),
          const SizedBox(height: 5),
          const Text(
              'Follow the work, inspect the evidence, and keep the run moving.',
              style: TextStyle(color: Color(0xff777683), fontSize: 13))
        ])),
        FilledButton.icon(
            onPressed: () => setState(() => showNewGoal = true),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New goal'),
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xff6254d9),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 13))),
      ]),
      const SizedBox(height: 25),
      _runHeader(compact),
      const SizedBox(height: 16),
      if (compact) ...[
        _executionCard(),
        const SizedBox(height: 16),
        _taskDetailsCard()
      ] else
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 6, child: _executionCard()),
          const SizedBox(width: 16),
          Expanded(flex: 4, child: _taskDetailsCard())
        ]),
      const SizedBox(height: 16),
      if (compact) ...[
        _timelineCard(),
        const SizedBox(height: 16),
        _evidenceCard()
      ] else
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 6, child: _timelineCard()),
          const SizedBox(width: 16),
          Expanded(flex: 4, child: _evidenceCard())
        ]),
      if (showWorkerDrawer) ...[const SizedBox(height: 16), _workerStrip()],
      if (showNewGoal) _newGoalDialog(),
    ]);
  }

  Widget _runHeader(bool compact) {
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
                  const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Build a useful Conclave Studio UI',
                            style: TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14)),
                        SizedBox(height: 4),
                        Text('Run R-042  ·  Forge  ·  started 2 min ago',
                            style: TextStyle(
                                color: Color(0xff898896), fontSize: 11))
                      ]),
                  _statusChip(
                      isPaused ? 'Paused' : 'Running',
                      isPaused
                          ? const Color(0xffedb84d)
                          : const Color(0xff40ae7d)),
                  const SizedBox(width: 5),
                  if (!compact)
                    const Text('Standard verification',
                        style:
                            TextStyle(color: Color(0xff777683), fontSize: 11)),
                  OutlinedButton.icon(
                      onPressed: () => setState(() => isPaused = !isPaused),
                      icon: Icon(
                          isPaused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          size: 16),
                      label: Text(isPaused ? 'Resume' : 'Pause'),
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9))),
                  OutlinedButton.icon(
                      onPressed: () {},
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
    return _panel(
        title: 'Execution tree',
        subtitle: 'Live run state',
        trailing: _statusChip('68% complete', const Color(0xff6254d9)),
        child: Column(children: [
          _phaseRow('01', 'Understand', '1 / 1 tasks complete', true),
          _taskRow(snapshot.tasks[0]),
          _phaseRow('02', 'Build', '1 / 1 tasks active', true),
          _taskRow(snapshot.tasks[1], selected: true),
          _phaseRow('03', 'Verify', '0 / 2 tasks started', false),
          _taskRow(snapshot.tasks[2]),
          _taskRow(snapshot.tasks[3]),
        ]));
  }

  Widget _phaseRow(String number, String name, String detail, bool complete) =>
      Padding(
          padding: const EdgeInsets.fromLTRB(2, 13, 2, 7),
          child: Row(children: [
            Container(
                width: 23,
                height: 23,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: complete
                        ? const Color(0xffe8f7f0)
                        : const Color(0xfff0eff4),
                    borderRadius: BorderRadius.circular(7)),
                child: Text(number,
                    style: TextStyle(
                        fontSize: 10,
                        color: complete
                            ? const Color(0xff329b6c)
                            : const Color(0xff858391),
                        fontWeight: FontWeight.w700))),
            const SizedBox(width: 9),
            Text(name,
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
            const SizedBox(width: 8),
            Text(detail,
                style: const TextStyle(color: Color(0xff96949e), fontSize: 11)),
            const Spacer(),
            Icon(complete ? Icons.check_circle_rounded : Icons.more_horiz,
                size: 16,
                color: complete
                    ? const Color(0xff42b27d)
                    : const Color(0xffb0afb8))
          ]));

  Widget _taskRow(StudioTask task, {bool selected = false}) {
    final active = selectedTaskId == task.id;
    final color = task.status == TaskStatus.completed
        ? const Color(0xff43b17f)
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
    final task = selectedTask ?? snapshot.tasks.first;
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
          const SizedBox(height: 18),
          _detailLine(Icons.person_outline, 'Worker', task.worker),
          _detailLine(
              Icons.account_tree_outlined,
              'Dependencies',
              task.dependencies.isEmpty
                  ? 'None'
                  : task.dependencies.join(', ')),
          _detailLine(Icons.token_outlined, 'Usage',
              '${task.tokens} tokens  ·  ${task.cost}'),
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
        trailing: TextButton(onPressed: () {}, child: const Text('View all')),
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
      subtitle: '2 findings · 3 artifacts',
      trailing: TextButton(
          onPressed: () => setState(() => navigationIndex = 3),
          child: const Text('Open evidence')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _metric('Tokens', '32.5k'),
          _metric('Cost', '\$0.65'),
          _metric('Checks', '0 / 2')
        ]),
        const SizedBox(height: 16),
        ...snapshot.findings.map((finding) => _findingRow(finding))
      ]));

  Widget _metric(String label, String value) => Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(color: Color(0xff9a98a3), fontSize: 10)),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Color(0xff393743)))
      ]));

  Widget _findingRow(StudioFinding finding) => Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: const Color(0xfffffaf4),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xfff2e6d3))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(
            finding.status == FindingStatus.verified
                ? Icons.verified_rounded
                : Icons.warning_amber_rounded,
            size: 17,
            color: finding.status == FindingStatus.verified
                ? const Color(0xff42ae7e)
                : const Color(0xffd49a38)),
        const SizedBox(width: 8),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(finding.title,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 11)),
          const SizedBox(height: 3),
          Text('${finding.severity.name} · ${finding.status.name}',
              style: const TextStyle(color: Color(0xff9b8a70), fontSize: 10))
        ]))
      ]));

  Widget _panel(
          {required String title,
          required String subtitle,
          required Widget child,
          Widget? trailing}) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 14)),
                      const SizedBox(height: 3),
                      Text(subtitle,
                          style: const TextStyle(
                              color: Color(0xffaaa8b1), fontSize: 10)),
                    ],
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

  Widget _workerStrip() => _panel(
      title: 'Worker registry',
      subtitle: 'Capability-based routing',
      child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: snapshot.workers
              .map((worker) => Chip(
                  avatar: const Icon(Icons.circle,
                      size: 8, color: Color(0xff55bf8f)),
                  label: Text('${worker.name} · ${worker.provider}')))
              .toList()));

  Widget _workersView() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Workers',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('Configured resources resolved by role and capability.',
              style: TextStyle(color: Color(0xff777683), fontSize: 13)),
          const SizedBox(height: 24),
          ...snapshot.workers.map(
            (worker) => Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                leading: CircleAvatar(
                  backgroundColor: const Color(0xffeeecff),
                  child: Icon(
                      worker.role == 'reviewer'
                          ? Icons.rate_review_outlined
                          : Icons.smart_toy_outlined,
                      color: const Color(0xff6254d9),
                      size: 20),
                ),
                title: Text(worker.name,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(
                    '${worker.provider} · ${worker.role} · ${worker.capabilities.join(' · ')}'),
                trailing: _statusChip(worker.status, const Color(0xff43b17f)),
              ),
            ),
          ),
        ],
      );

  Widget _artifactsView() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Artifacts & evidence',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text(
              'Every report, output, screenshot, and check remains attached to the run.',
              style: TextStyle(color: Color(0xff777683), fontSize: 13)),
          const SizedBox(height: 24),
          _panel(
            title: 'Run R-042',
            subtitle: 'Forge · 3 artifacts',
            child: Column(
              children: snapshot.artifacts
                  .map(
                    (artifact) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.description_outlined,
                          color: Color(0xff6254d9)),
                      title: Text(artifact.name,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                      subtitle: Text('${artifact.type} · ${artifact.source}'),
                      trailing: Text(artifact.size,
                          style: const TextStyle(
                              color: Color(0xff888691), fontSize: 11)),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      );

  Widget _settingsView() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Settings',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('Studio preferences and connection status.',
              style: TextStyle(color: Color(0xff777683), fontSize: 13)),
          const SizedBox(height: 24),
          _panel(
              title: 'Connection',
              subtitle: 'Platform services',
              child: _detailLine(Icons.devices_other_outlined, 'Platform',
                  widget.services.platformName)),
          _panel(
            title: 'Verification defaults',
            subtitle: 'Applied to new Forge goals',
            child: const Column(
              children: [
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Standard verification'),
                    subtitle: Text('Independent review and blocking findings'),
                    trailing:
                        Icon(Icons.check_circle, color: Color(0xff43b17f))),
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Pause before completion'),
                    subtitle: Text(
                        'Ask for approval when all automated evidence is present'),
                    trailing: Icon(Icons.toggle_off_outlined,
                        color: Color(0xff96949e))),
              ],
            ),
          ),
        ],
      );

  Widget _newGoalDialog() => Card(
        margin: const EdgeInsets.only(top: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 510),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Create a goal',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                const Text('Start a new run in the selected project.',
                    style: TextStyle(color: Color(0xff777683), fontSize: 12)),
                const SizedBox(height: 18),
                const TextField(
                    decoration: InputDecoration(
                        labelText: 'What should Conclave accomplish?',
                        hintText: 'Describe the outcome, not just the task',
                        border: OutlineInputBorder())),
                const SizedBox(height: 14),
                const TextField(
                    decoration: InputDecoration(
                        labelText: 'Repository revision',
                        hintText: 'main',
                        border: OutlineInputBorder())),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                        onPressed: () => setState(() => showNewGoal = false),
                        child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    FilledButton(
                        onPressed: () => setState(() => showNewGoal = false),
                        child: const Text('Create goal')),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
