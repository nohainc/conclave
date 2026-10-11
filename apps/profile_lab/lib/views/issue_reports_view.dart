import 'dart:convert';

import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../widgets/lab_components.dart';
import '../theme/profile_lab_theme.dart';

/// Support-only issue investigation surface. The normal AX applications never
/// expose these routes or this view.
class IssueReportsView extends StatefulWidget {
  const IssueReportsView({super.key, required this.controller});
  final ProfileLabController controller;

  @override
  State<IssueReportsView> createState() => _IssueReportsViewState();
}

class _IssueReportsViewState extends State<IssueReportsView> {
  String _status = 'all';
  String _query = '';
  String _component = 'all';
  String _worker = 'all';
  DateTime? _from;
  DateTime? _to;

  ProfileLabController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final reports = c.issueReports.where((report) {
      final statusMatches = _status == 'all' || report['status'] == _status;
      final componentMatches = _component == 'all' || report['component'] == _component;
      final workerMatches = _worker == 'all' || report['workerTypeId'] == _worker;
      final created = DateTime.tryParse('${report['createdAt']}');
      final dateMatches = created == null ||
          (_from == null || !created.isBefore(_from!)) &&
          (_to == null || created.isBefore(_to!.add(const Duration(days: 1))));
      final searchable = [
        report['publicReference'],
        report['errorCode'],
        report['component'],
        report['workerTypeId'],
        report['modelId'],
      ].whereType<Object>().join(' ').toLowerCase();
      return statusMatches && componentMatches && workerMatches && dateMatches && searchable.contains(_query.toLowerCase());
    }).toList();
    final components = c.issueReports.map((r) => '${r['component']}').toSet().toList()..sort();
    final workers = c.issueReports.map((r) => '${r['workerTypeId']}').where((v) => v != 'null').toSet().toList()..sort();
    final selected = c.selectedIssueReport;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        LabPageHeader(
          title: 'Issue investigation',
          description:
              'Review reported failures, correlate execution evidence and manage incident groups.',
          actions: [
            IconButton(
              tooltip: 'Refresh issue reports',
              icon: const Icon(Icons.refresh),
              onPressed: c.isLoadingIssueReports ? null : c.fetchIssueReports,
            ),
          ],
        ),
        Wrap(spacing: 12, runSpacing: 8, children: [
          SizedBox(
            width: 150,
            child: DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Status'),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('All statuses')),
                DropdownMenuItem(value: 'open', child: Text('Open')),
                DropdownMenuItem(value: 'investigating', child: Text('Investigating')),
                DropdownMenuItem(value: 'resolved', child: Text('Resolved')),
                DropdownMenuItem(value: 'dismissed', child: Text('Dismissed')),
              ],
              onChanged: (value) => setState(() => _status = value ?? 'all'),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 170,
            child: DropdownButtonFormField<String>(
              initialValue: _component,
              decoration: const InputDecoration(labelText: 'Component'),
              items: [
                const DropdownMenuItem(value: 'all', child: Text('All components')),
                ...components.map((value) => DropdownMenuItem(value: value, child: Text(value))),
              ],
              onChanged: (value) => setState(() => _component = value ?? 'all'),
            ),
          ),
          SizedBox(
            width: 160,
            child: DropdownButtonFormField<String>(
              initialValue: _worker,
              decoration: const InputDecoration(labelText: 'Worker'),
              items: [
                const DropdownMenuItem(value: 'all', child: Text('All workers')),
                ...workers.map((value) => DropdownMenuItem(value: value, child: Text(value))),
              ],
              onChanged: (value) => setState(() => _worker = value ?? 'all'),
            ),
          ),
          SizedBox(
            width: 250,
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'Filter reports',
                hintText: 'Reference, error, component, worker or model',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => _query = value.trim()),
            ),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.date_range, size: 16),
            label: Text(_from == null ? 'Date range' : '${_from!.toIso8601String().substring(0, 10)} – ${_to?.toIso8601String().substring(0, 10) ?? '…'}'),
            onPressed: () async {
              final range = await showDateRangePicker(
                context: context,
                firstDate: DateTime(2020),
                lastDate: DateTime.now().add(const Duration(days: 1)),
                initialDateRange: _from == null ? null : DateTimeRange(start: _from!, end: _to ?? _from!),
              );
              if (range != null) setState(() { _from = range.start; _to = range.end; });
            },
          ),
        ]),
        if (c.isLoadingIssueReports) const OperationProgress(label: 'Loading issue reports…'),
        if (c.issueReportsError != null)
          ErrorState(
            message: c.issueReportsError!,
            onRetry: c.isLoadingIssueReports ? null : c.fetchIssueReports,
          ),
        const SizedBox(height: 12),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              flex: 5,
              child: reports.isEmpty
                  ? const EmptyState(title: 'No issue reports match the filter.')
                  : ListView.separated(
                      itemCount: reports.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final report = reports[index];
                        final isSelected = selected?['report']?['id'] == report['id'];
                        final group = report['incidentGroup'] as Map?;
                        return Card(
                          color: isSelected
                              ? ProfileLabTheme.primaryAccent.withValues(alpha: .15)
                              : null,
                          child: ListTile(
                            selected: isSelected,
                            title: Text('${report['publicReference']} · ${report['errorCode']}'),
                            subtitle: Text(
                              '${report['component']} · ${report['workerTypeId'] ?? 'Unknown worker'} · ${report['diagnosticState']}\nEngine ${((report['versions'] as Map?)?['engine']) ?? '?'} · Provider ${((report['versions'] as Map?)?['providerTool']) ?? '?'} · ${report['createdAt']}',
                            ),
                            isThreeLine: true,
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                _StatusChip(status: '${report['status']}'),
                                if (group != null)
                                  Text('${group['publicReference'] ?? 'Grouped'} (${group['count'] ?? 0})', style: const TextStyle(fontSize: 10)),
                                if (group == null && (report['fingerprintGroup'] as Map?)?['count'] is int && ((report['fingerprintGroup'] as Map)['count'] as int) > 1)
                                  Text('Fingerprint group (${(report['fingerprintGroup'] as Map)['count']})', style: const TextStyle(fontSize: 10)),
                              ],
                            ),
                            onTap: () => c.selectIssueReport('${report['id']}'),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 7,
              child: selected == null
                  ? const Card(child: EmptyState(title: 'Select a report to investigate.'))
                  : _IssueDetail(controller: c, data: selected),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final String status;
  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'resolved' => Colors.green,
      'dismissed' => Colors.grey,
      'investigating' => Colors.orange,
      _ => Colors.red,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: .2), borderRadius: BorderRadius.circular(10)),
      child: Text(status, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }
}

class _IssueDetail extends StatelessWidget {
  const _IssueDetail({required this.controller, required this.data});
  final ProfileLabController controller;
  final Map<String, dynamic> data;

  Future<void> _changeStatus(BuildContext context, String status) async {
    final report = data['report'] as Map?;
    final id = report?['id'] as String?;
    if (id == null) return;
    await controller.updateIssueReport(id, status: status);
  }

  Future<void> _addNote(BuildContext context) async {
    final note = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add internal note'),
        content: TextField(controller: note, autofocus: true, maxLines: 4),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, note.text.trim()), child: const Text('Save note')),
        ],
      ),
    );
    note.dispose();
    final id = (data['report'] as Map?)?['id'] as String?;
    if (value != null && value.isNotEmpty && id != null) {
      await controller.updateIssueReport(id, note: value, status: (data['report'] as Map)['status'] as String?);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = (data['report'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final investigation = (data['investigation'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final timeline = (data['timeline'] as List?) ?? const [];
    final missing = (investigation['missingEvidence'] as List?)?.whereType<Object>().toList() ?? const [];
    final versions = (investigation['versions'] as Map?) ?? const {};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('${report['publicReference'] ?? 'Issue report'}', style: Theme.of(context).textTheme.titleLarge)),
            _StatusChip(status: '${report['status'] ?? 'open'}'),
            PopupMenuButton<String>(
              tooltip: 'Change status',
              onSelected: (value) => _changeStatus(context, value),
              itemBuilder: (_) {
                final current = '${report['status'] ?? 'open'}';
                return [
                  if (current == 'open' || current == 'investigating')
                    const PopupMenuItem(value: 'investigating', child: Text('Investigating')),
                  if (current == 'investigating') ...const [
                    PopupMenuItem(value: 'resolved', child: Text('Resolved')),
                    PopupMenuItem(value: 'dismissed', child: Text('Dismissed')),
                  ],
                ];
              },
            ),
            IconButton(tooltip: 'Add internal note', icon: const Icon(Icons.note_add_outlined), onPressed: () => _addNote(context)),
          ]),
          Text('${report['errorCode']} · ${report['component']} · ${report['failureStage']}'),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 6, children: [
            _Fact(label: 'Worker', value: '${report['workerTypeId'] ?? 'Unknown'}'),
            _Fact(label: 'Model', value: '${report['modelId'] ?? 'Unknown'}'),
            _Fact(label: 'Effort', value: '${report['effort'] ?? 'Unknown'}'),
            _Fact(label: 'Engine', value: '${versions['engine'] ?? 'Unknown'}'),
            _Fact(label: 'Profile', value: '${versions['profileDefinition'] ?? 'Unknown'} v${versions['profileRelease'] ?? '?'}'),
            _Fact(label: 'Provider', value: '${versions['providerTool'] ?? 'Unknown'}'),
            _Fact(label: 'Diagnostics', value: '${report['diagnosticState'] ?? 'Unknown'}'),
          ]),
          if (missing.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Missing evidence: ${missing.join(', ')}', style: const TextStyle(color: Colors.orange)),
          ],
          const SizedBox(height: 8),
          Row(children: [
            const Text('Incident group: ', style: TextStyle(fontWeight: FontWeight.w600)),
            Expanded(
              child: DropdownButton<String?>(
                isExpanded: true,
                value: (report['incidentGroup'] as Map?)?['id'] as String?,
                hint: const Text('No group'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('No group')),
                  ...controller.issueReportGroups.map((group) => DropdownMenuItem<String?>(
                        value: group['id'] as String?,
                        child: Text('${group['publicReference'] ?? ''} · ${group['label'] ?? ''}'),
                      )),
                ],
                onChanged: (groupId) {
                  final id = report['id'] as String?;
                  if (id != null) {
                    controller.updateIssueReport(id, groupId: groupId, clearGroup: groupId == null);
                  }
                },
              ),
            ),
          ]),
          const Divider(height: 24),
          const Text('Execution timeline', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Expanded(
            child: timeline.isEmpty
                ? const EmptyState(title: 'No correlated timeline is available.')
                : ListView.builder(
                    itemCount: timeline.length,
                    itemBuilder: (context, index) {
                      final event = (timeline[index] as Map).cast<String, dynamic>();
                      return ListTile(
                        dense: true,
                        leading: Icon(event['severity'] == 'error' ? Icons.error_outline : Icons.timeline, color: event['severity'] == 'error' ? Colors.red : null),
                        title: Text('${event['eventType'] ?? 'event'} · ${event['component'] ?? event['source'] ?? ''}'),
                        subtitle: Text('${event['timestamp'] ?? ''}  ${event['stage'] ?? ''}  ${event['errorCode'] ?? ''}'),
                        trailing: event['details'] is Map ? Tooltip(message: const JsonEncoder().convert(event['details']), child: const Icon(Icons.info_outline, size: 16)) : null,
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Chip(label: Text('$label: $value'));
}
