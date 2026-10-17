import 'dart:async';

import 'package:flutter/material.dart';

import '../../ax/ax_models.dart';
import '../../ax/ax_workspace_member_access.dart';
import '../common/quiet_notices.dart';

/// Owner control for what invited Space members can use on a Workspace. When
/// unrestricted, members use whatever the owner's workflows select. When
/// restricted, only the listed Workers, models and efforts can run for them;
/// Cloud enforces this when a request is created.
class WorkspaceMemberAccessSection extends StatefulWidget {
  const WorkspaceMemberAccessSection({
    super.key,
    required this.workspaceId,
    required this.workers,
    required this.source,
    this.personSource,
    this.userId,
    this.personName,
  }) : assert((personSource == null) == (userId == null));

  final String workspaceId;
  final List<AxWorker> workers;
  final AxWorkspaceMemberAccessDataSource source;

  /// When set, edits one person's access instead of the Workspace default:
  /// the policy always applies (no "limit" switch) and can be reset to the
  /// default.
  final AxWorkspacePersonAccessDataSource? personSource;
  final String? userId;
  final String? personName;

  @override
  State<WorkspaceMemberAccessSection> createState() =>
      _WorkspaceMemberAccessSectionState();
}

class _WorkspaceMemberAccessSectionState
    extends State<WorkspaceMemberAccessSection> {
  bool _loading = true;
  bool _saving = false;
  Object? _error;
  AxWorkspaceMemberAccess _saved = const AxWorkspaceMemberAccess();
  bool _restricted = false;
  String? _mode;
  Map<String, AxSharedWorker> _workers = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(WorkspaceMemberAccessSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspaceId != widget.workspaceId) unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final workspaceId = widget.workspaceId;
    try {
      final person = widget.personSource;
      final access = person == null
          ? await widget.source.loadWorkspaceMemberAccess(workspaceId)
          : _personAccess(
              await person.loadPersonAccess(workspaceId, widget.userId!));
      if (!mounted || workspaceId != widget.workspaceId) return;
      setState(() => _adopt(access));
    } catch (error) {
      if (mounted && workspaceId == widget.workspaceId) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && workspaceId == widget.workspaceId) {
        setState(() => _loading = false);
      }
    }
  }

  /// A person's policy always applies, so it is edited as a restricted one that
  /// starts at the safest mode.
  AxWorkspaceMemberAccess _personAccess(AxPersonAccess person) {
    _custom = person.custom;
    return AxWorkspaceMemberAccess(
        restricted: true,
        mode: person.access.mode ?? 'chat',
        workers: person.access.workers);
  }

  bool _custom = false;
  bool get _isPerson => widget.personSource != null;

  Future<void> _reset() async {
    setState(() => _saving = true);
    try {
      final next = await widget.personSource!
          .resetPersonAccess(widget.workspaceId, widget.userId!);
      if (mounted) setState(() => _adopt(_personAccess(next)));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showNotice(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _adopt(AxWorkspaceMemberAccess access) {
    _saved = access;
    _restricted = access.restricted;
    _mode = access.mode;
    _workers = Map.of(access.workers);
  }

  bool get _dirty =>
      _restricted != _saved.restricted ||
      (_restricted &&
          (_mode != _saved.mode || !_sameWorkers(_workers, _saved.workers)));

  static bool _sameWorkers(
      Map<String, AxSharedWorker> a, Map<String, AxSharedWorker> b) {
    if (a.length != b.length) return false;
    bool same(List<String>? x, List<String>? y) => x == null || y == null
        ? x == y
        : x.length == y.length && x.toSet().containsAll(y);
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null ||
          !same(entry.value.models, other.models) ||
          !same(entry.value.efforts, other.efforts)) {
        return false;
      }
    }
    return true;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final next = AxWorkspaceMemberAccess(
          restricted: _restricted,
          mode: _restricted ? _mode : null,
          workers: _restricted ? _workers : const {});
      final person = widget.personSource;
      final access = person == null
          ? await widget.source
              .saveWorkspaceMemberAccess(widget.workspaceId, next)
          : _personAccess(await person.savePersonAccess(
              widget.workspaceId, widget.userId!, next));
      if (mounted) setState(() => _adopt(access));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showNotice(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Toggle [value] in a null-means-all list limited to [all].
  List<String>? _toggle(List<String>? current, String value, List<String> all) {
    final selected = Set<String>.of(current ?? all);
    if (!selected.remove(value)) selected.add(value);
    // Everything selected is the same as sharing all of them.
    return selected.length == all.length ? null : selected.toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final workers = widget.workers
        .where((worker) =>
            worker.workspaceId == widget.workspaceId &&
            worker.status != 'removed')
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
            _isPerson
                ? 'Access for ${widget.personName ?? 'this person'}'
                : 'Member access',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(
            _isPerson
                ? (_custom
                    ? 'Custom access replaces the Workspace default for this person.'
                    : 'This person follows the Workspace default until you save custom access.')
                : 'Choose what invited Space members can use on this Workspace. You are never limited.',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        if (_loading)
          const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          Row(children: [
            const Expanded(child: Text('Member access could not be loaded.')),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ])
        else ...[
          if (!_isPerson)
            SwitchListTile(
                key: const ValueKey('member-access-restricted'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Limit what members can use'),
                subtitle: Text(_restricted
                    ? 'Members can only use what is shared below.'
                    : 'Members use whatever your workflows select.'),
                value: _restricted,
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                          _restricted = value;
                          // New limits start at the safest mode (ADR-020).
                          if (value) _mode ??= 'chat';
                        })),
          if (_restricted) ...[
            _modeSelector(context),
            if (workers.isEmpty)
              Text('This Workspace has no Workers to share yet.',
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
            for (final worker in workers) _workerTile(context, worker),
          ],
          const SizedBox(height: 8),
          Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                  key: const ValueKey('member-access-save'),
                  onPressed: _dirty && !_saving ? _save : null,
                  child: const Text('Save access'))),
          if (_isPerson && _custom)
            Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                    key: const ValueKey('person-access-reset'),
                    onPressed: _saving ? null : _reset,
                    child: const Text('Reset to default'))),
        ],
      ],
    );
  }

  static const _modeLabels = {
    'chat': 'Chat only',
    'work': 'Chat and work',
    'work+shell': 'Work and commands',
  };

  /// The ceiling on what members may run: read-only chat, file changes, or
  /// also shell commands.
  Widget _modeSelector(BuildContext context) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(spacing: 8, runSpacing: 4, children: [
        const Text('Members can:'),
        for (final mode in axWorkspaceAccessModes)
          ChoiceChip(
              key: ValueKey('member-mode-$mode'),
              label: Text(_modeLabels[mode]!),
              selected: _mode == mode,
              onSelected: _saving ? null : (_) => setState(() => _mode = mode)),
      ]));

  Widget _workerTile(BuildContext context, AxWorker worker) {
    final shared = _workers[worker.id];
    final models =
        (worker.executionOptions?.models ?? const <AxWorkerModelOption>[])
            .where((model) => model.status != 'unavailable')
            .toList(growable: false);
    final efforts = <String>{
      for (final model in models) ...model.effort.values,
    }.toList(growable: false);
    final modelIds = [for (final model in models) model.id];
    Widget chips(
        String label,
        List<String> ids,
        Map<String, String> names,
        List<String>? selected,
        ValueChanged<List<String>?> onChanged,
        String keyPrefix) {
      if (ids.isEmpty) return const SizedBox.shrink();
      return Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Wrap(spacing: 8, runSpacing: 4, children: [
            Text('$label:'),
            FilterChip(
                key: ValueKey('$keyPrefix-all-${worker.id}'),
                label: const Text('All'),
                selected: selected == null,
                onSelected: (_) => onChanged(null)),
            for (final id in ids)
              FilterChip(
                  key: ValueKey('$keyPrefix-$id-${worker.id}'),
                  label: Text(names[id] ?? id),
                  selected: selected == null || selected.contains(id),
                  onSelected: (_) => onChanged(_toggle(selected, id, ids))),
          ]));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      CheckboxListTile(
          key: ValueKey('share-worker-${worker.id}'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(worker.displayName),
          value: shared != null,
          onChanged: _saving
              ? null
              : (value) => setState(() {
                    if (value == true) {
                      _workers[worker.id] = const AxSharedWorker();
                    } else {
                      _workers.remove(worker.id);
                    }
                  })),
      if (shared != null) ...[
        chips('Models', modelIds, {for (final m in models) m.id: m.name},
            shared.models, (value) {
          setState(() => _workers[worker.id] =
              AxSharedWorker(models: value, efforts: shared.efforts));
        }, 'member-model'),
        chips('Efforts', efforts, const {}, shared.efforts, (value) {
          setState(() => _workers[worker.id] =
              AxSharedWorker(models: shared.models, efforts: value));
        }, 'member-effort'),
      ],
    ]);
  }
}
