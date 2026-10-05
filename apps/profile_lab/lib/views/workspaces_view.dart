import 'package:flutter/material.dart';
import '../widgets/lab_components.dart';
import '../controllers/profile_lab_controller.dart';
import 'profile_lab_step_up.dart';

class WorkspacesView extends StatefulWidget {
  const WorkspacesView({super.key, required this.controller});
  final ProfileLabController controller;
  @override
  State<WorkspacesView> createState() => _WorkspacesViewState();
}

class _WorkspacesViewState extends State<WorkspacesView> {
  String _search = '';
  Future<void> _change(Map<String, dynamic> workspace, String channel) async {
    final c = widget.controller;
    final id = workspace['id'] as String;
    final from = workspace['channel'] as String? ?? 'stable';
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Change rollout channel?'),
                content: Text(
                    '${workspace['name'] ?? id}: ${_label(from)} → ${_label(channel)}.\n\nThis changes which signed Profile releases this Workspace receives when it next resolves Profiles. Running sessions keep their pinned release.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Change channel'))
                ]));
    if (confirmed != true || !mounted) return;
    // A refreshed assignment while confirmation was open requires a new choice.
    final current = c.workspaceChannels.where((w) => w['id'] == id).firstOrNull;
    if (current == null || (current['channel'] ?? 'stable') != from) return;
    await c.updateWorkspaceChannel(id, channel);
    if (!mounted || c.workspaceError == null) return;
    showProfileLabOperationFailure(
        context, c, 'Workspace channel update', StateError(c.workspaceError!));
  }

  String _label(String value) => value.isEmpty
      ? 'Unknown'
      : '${value[0].toUpperCase()}${value.substring(1)}';
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final rows = c.workspaceChannels
        .where((w) => ['name', 'id', 'hostname'].any((key) =>
            '${w[key] ?? ''}'.toLowerCase().contains(_search.toLowerCase())))
        .toList();
    return Padding(
        padding: const EdgeInsets.all(20),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          LabPageHeader(
              title: 'Workspace rollout',
              description:
                  'Choose which signed Profile release channel each Workspace receives.',
              actions: [
                IconButton(
                    tooltip: 'About rollout channels',
                    icon: const Icon(Icons.info_outline),
                    onPressed: () => showDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                                title: const Text('Rollout channels'),
                                content: const Text(
                                    'Testing is for test machines, Beta for pilot Workspaces, and Stable for general use. The channel selects signed Profile releases without updating the Workspace app. Channel changes do not retarget running sessions. Connection shows the latest status reported to Cloud.'),
                                actions: [
                                  TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('Close'))
                                ]))),
                IconButton(
                    tooltip: 'Refresh Workspaces (⌘R)',
                    onPressed:
                        c.isLoadingWorkspaces ? null : c.fetchWorkspaceChannels,
                    icon: const Icon(Icons.refresh))
              ]),
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 8, children: [
            Chip(label: Text('Total: ${c.workspaceChannels.length}')),
            for (final channel in ['testing', 'beta', 'stable'])
              Chip(
                  label: Text(
                      '${_label(channel)}: ${c.workspaceChannels.where((w) => (w['channel'] ?? 'stable') == channel).length}'))
          ]),
          const SizedBox(height: 12),
          TextField(
              onChanged: (value) => setState(() => _search = value),
              decoration: const InputDecoration(
                  hintText: 'Search workspaces...',
                  prefixIcon: Icon(Icons.search))),
          if (c.isLoadingWorkspaces) const OperationProgress(label: 'Loading…'),
          if (c.workspaceError != null)
            ErrorState(
                message:
                    'Workspace update or lookup failed: ${c.workspaceError}',
                onRetry:
                    c.isLoadingWorkspaces ? null : c.fetchWorkspaceChannels),
          const SizedBox(height: 12),
          Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: EmptyState(
                          title: c.isLoadingWorkspaces
                              ? 'Loading Workspaces…'
                              : _search.isEmpty
                                  ? 'No registered Workspaces found.'
                                  : 'No Workspaces match your search.'))
                  : LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                          child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                      minWidth: constraints.maxWidth),
                                  child: DataTable(columns: const [
                                    DataColumn(label: Text('Workspace')),
                                    DataColumn(label: Text('Host')),
                                    DataColumn(label: Text('App version')),
                                    DataColumn(label: Text('Connection')),
                                    DataColumn(label: Text('Channel'))
                                  ], rows: [
                                    for (final w in rows)
                                      DataRow(cells: [
                                        DataCell(Tooltip(
                                            message: '${w['id']}',
                                            child: Text(
                                                '${w['name'] ?? w['id']}'))),
                                        DataCell(Text(
                                            '${w['hostname'] ?? 'Unknown'}')),
                                        DataCell(Text(
                                            '${w['appVersion'] ?? 'Unknown'}')),
                                        DataCell(Text(_label(
                                            w['status'] as String? ??
                                                'unknown'))),
                                        DataCell(SizedBox(
                                            width: 140,
                                            child: DropdownButton<String>(
                                                key: ValueKey(
                                                    'workspace-channel-${w['id']}'),
                                                value:
                                                    w['channel'] as String? ??
                                                        'stable',
                                                isExpanded: true,
                                                items: [
                                                  for (final channel in [
                                                    'testing',
                                                    'beta',
                                                    'stable'
                                                  ])
                                                    DropdownMenuItem(
                                                        value: channel,
                                                        child: Text(
                                                            _label(channel)))
                                                ],
                                                onChanged: c
                                                        .updatingWorkspaceIds
                                                        .contains(w['id'])
                                                    ? null
                                                    : (channel) {
                                                        if (channel != null &&
                                                            channel !=
                                                                (w['channel'] ??
                                                                    'stable')) {
                                                          _change(w, channel);
                                                        }
                                                      })))
                                      ]),
                                  ]))))))
        ]));
  }
}
