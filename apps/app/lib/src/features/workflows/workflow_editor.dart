import 'package:flutter/material.dart';
import '../../ax/ax_models.dart';
import '../../ax/ax_workflow_configuration.dart';
import '../../ax/workflow_configuration_options.dart';
import '../../ax/sync/ax_query_builder.dart';
import '../../ax/sync/ax_session_catalogs.dart';
import '../../ax/sync/ax_workflow_configurations.dart';

/// Fixed, Conclave-owned steps. Only execution preferences are editable here.
class WorkflowEditor extends StatefulWidget {
  const WorkflowEditor(
      {super.key,
      required this.definition,
      required this.configuration,
      required this.catalogs,
      required this.cache,
      this.workspaceId});
  final String? workspaceId;
  final AxBuiltinWorkflow definition;
  final AxUserWorkflowConfiguration configuration;
  final AxSessionCatalogs catalogs;
  final AxWorkflowConfigurations cache;
  @override
  State<WorkflowEditor> createState() => _WorkflowEditorState();
}

class _WorkflowEditorState extends State<WorkflowEditor> {
  late bool enabled = widget.configuration.enabled;
  late AxWorkflowSelection defaults = widget.configuration.defaults;
  late final overrides =
      Map<String, AxWorkflowSelection>.from(widget.configuration.stepOverrides);
  late final overriding = overrides.keys.toSet();
  bool busy = false;
  String? error;

  List<AxBuiltinWorkflowStep> get steps =>
      [...widget.definition.steps]..sort((a, b) => a.order.compareTo(b.order));
  AxUserWorkflowConfiguration get draft => AxUserWorkflowConfiguration(
        workflowId: widget.definition.id,
        enabled: enabled,
        defaults: defaults,
        stepOverrides: {
          for (final id in overriding)
            if (overrides[id]?.toJson().isNotEmpty == true) id: overrides[id]!
        },
      );
  Map<String, String> _issues(AxWorkflowSelectionOptions options) {
    final result = <String, String>{};
    final defaultError =
        options.validate(defaults, saved: widget.configuration.defaults);
    if (defaultError != null) result['defaults'] = defaultError;
    for (final step in steps) {
      final issue = options.validate(draft.selectionFor(step.kind),
          saved: draft.stepOverrides[step.kind] == null
              ? widget.configuration.defaults
              : widget.configuration.selectionFor(step.kind));
      if (issue != null) result[step.kind] = issue;
    }
    return result;
  }

  Future<void> _save({bool reset = false}) async {
    final workers = widget.catalogs.engine.peek(widget.catalogs.workers).data ??
        const <AxWorker>[];
    if (!reset &&
        _issues(AxWorkflowSelectionOptions(workers
                .where((worker) =>
                    widget.workspaceId == null ||
                    worker.workspaceId == widget.workspaceId)
                .toList()))
            .isNotEmpty) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (reset) {
        await widget.cache.reset(widget.definition.id);
      } else {
        await widget.cache.save(draft);
      }
      if (mounted) {
        setState(() => busy = false);
        Navigator.pop(context);
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          busy = false;
          error = failure.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !busy,
        child: AxQueryBuilder(
          engine: widget.catalogs.engine,
          query: widget.catalogs.workers,
          ensure: false,
          builder: (context, state) {
            final options = AxWorkflowSelectionOptions(
                (state.data ?? const <AxWorker>[])
                    .where((worker) =>
                        widget.workspaceId == null ||
                        worker.workspaceId == widget.workspaceId)
                    .toList());
            final issues = _issues(options);
            return AlertDialog(
              title: Text(widget.definition.name),
              content: SizedBox(
                  width: 480,
                  child: SingleChildScrollView(
                      child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Enabled'),
                          value: enabled,
                          subtitle: widget.definition.id == 'chat'
                              ? const Text('Chat is always available.')
                              : null,
                          onChanged: busy || widget.definition.id == 'chat'
                              ? null
                              : (value) => setState(() => enabled = value)),
                      Text('Default execution',
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 12),
                      _selection(
                          'defaults',
                          defaults,
                          const AxWorkflowSelection(),
                          options,
                          (value) => defaults = value),
                      if (issues['defaults'] != null)
                        _notice(issues['defaults']!, error: true),
                      const SizedBox(height: 8),
                      ExpansionTile(
                        key: const ValueKey('workflow-advanced'),
                        tilePadding: EdgeInsets.zero,
                        title: const Text('Advanced'),
                        children: [
                          const Divider(),
                          const Align(
                              alignment: Alignment.centerLeft,
                              child: Text('Workflow steps',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w600))),
                          const SizedBox(height: 8),
                          for (var index = 0; index < steps.length; index++)
                            _step(index, steps[index], options,
                                issues[steps[index].kind]),
                        ],
                      ),
                      if (issues.isNotEmpty)
                        _notice(
                            'Resolve incompatible choices before saving.\n${issues.entries.where((entry) => entry.key != 'defaults').map((entry) => '${_title(entry.key)}: ${entry.value}').join('\n')}',
                            error: true),
                      if (state.error != null)
                        _notice(
                            'Worker details could not be refreshed. Saved selections are retained.'),
                      if (error != null) _notice(error!, error: true),
                    ],
                  ))),
              actions: [
                TextButton(
                    key: const ValueKey('reset-workflow'),
                    onPressed: busy ? null : () => _save(reset: true),
                    child: Text(widget.cache.spaceId == null ||
                            widget.cache.engine
                                    .peek(widget.cache.workspaceQuery)
                                    .data
                                    ?.inherited ==
                                false
                        ? 'Reset'
                        : 'Use global defaults')),
                TextButton(
                    onPressed: busy ? null : () => Navigator.pop(context),
                    child: const Text('Cancel')),
                FilledButton(
                    key: const ValueKey('save-workflow'),
                    onPressed: busy || issues.isNotEmpty ? null : _save,
                    child: Text(busy ? 'Saving…' : 'Save')),
              ],
            );
          },
        ),
      );

  Widget _step(int index, AxBuiltinWorkflowStep step,
      AxWorkflowSelectionOptions options, String? issue) {
    final custom = overriding.contains(step.kind);
    final selection = overrides[step.kind] ?? const AxWorkflowSelection();
    return ExpansionTile(
      key: ValueKey('workflow-step-${step.kind}'),
      tilePadding: EdgeInsets.zero,
      title: Text('${index + 1}. ${_title(step.kind)}'),
      subtitle: Text(custom && selection.toJson().isNotEmpty
          ? _summary(selection, options)
          : 'Inherit defaults'),
      trailing: Icon(issue == null ? Icons.chevron_right : Icons.error_outline,
          color: issue == null ? null : Theme.of(context).colorScheme.error),
      children: [
        const Align(
            alignment: Alignment.centerLeft,
            child: Text('Execution',
                style: TextStyle(fontWeight: FontWeight.w600))),
        RadioGroup<bool>(
            groupValue: custom,
            onChanged: (value) {
              if (busy || value == null) return;
              setState(() {
                error = null;
                if (value) {
                  overriding.add(step.kind);
                } else {
                  overriding.remove(step.kind);
                  overrides.remove(step.kind);
                }
              });
            },
            child: Column(children: [
              RadioListTile<bool>(
                  key: ValueKey('inherit-${step.kind}'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use workflow defaults'),
                  value: false,
                  enabled: !busy),
              RadioListTile<bool>(
                  key: ValueKey('override-${step.kind}'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Override'),
                  value: true,
                  enabled: !busy),
            ])),
        if (custom) ...[
          const Text('Automatic inherits the corresponding workflow default.'),
          const SizedBox(height: 12),
          _selection(step.kind, selection, defaults, options,
              (value) => overrides[step.kind] = value),
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                  key: ValueKey('reset-step-${step.kind}'),
                  onPressed: busy
                      ? null
                      : () => setState(() {
                            overriding.remove(step.kind);
                            overrides.remove(step.kind);
                            error = null;
                          }),
                  child: const Text('Reset step to inherited values'))),
        ] else
          _notice('Uses the workflow Worker, model, and effort defaults.'),
        if (issue != null) _notice(issue, error: true),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _selection(
      String scope,
      AxWorkflowSelection value,
      AxWorkflowSelection base,
      AxWorkflowSelectionOptions options,
      ValueChanged<AxWorkflowSelection> update) {
    final effective = base.overlay(value);
    final selected = options.worker(effective.worker);
    final models = options.models(effective.worker);
    final efforts = options.efforts(effective);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _picker(
          scope,
          'Worker',
          value.worker,
          {
            for (final worker in options.workers)
              worker.id:
                  '${worker.displayName} · ${worker.workspaceName}${worker.isReady ? '' : ' · ${_availability(worker)}'}',
          },
          (id) => update(AxWorkflowSelection(worker: id)),
          inherited: base.worker),
      const SizedBox(height: 12),
      _picker(scope, 'Model', value.model, models,
          (id) => update(AxWorkflowSelection(worker: value.worker, model: id)),
          inherited: base.model),
      const SizedBox(height: 12),
      _picker(
          scope,
          'Effort',
          value.effort,
          {for (final id in efforts) id: _title(id)},
          (id) => update(AxWorkflowSelection(
              worker: value.worker, model: value.model, effort: id)),
          inherited: base.effort),
      const SizedBox(height: 12),
      if (effective.worker != null && (selected == null || !selected.isReady))
        _notice(selected == null
            ? 'Selected Worker is unavailable. Your saved selection is kept; choose another Worker to replace it.'
            : '${selected.displayName} is ${_availability(selected).toLowerCase()}. You can keep its configuration; execution requires an available Worker.'),
      if (selected != null && selected.executionOptions == null)
        _notice(
            'Model and effort options are unavailable until this Worker’s Profile capabilities are available.'),
    ]);
  }

  Widget _picker(String scope, String label, String? value,
      Map<String, String> choices, ValueChanged<String?> changed,
      {String? inherited}) {
    final available = Map<String, String>.from(choices);
    if (value != null && !available.containsKey(value)) {
      available[value] = '$value · Unavailable';
    }
    return DropdownButtonFormField<String>(
      key: ValueKey('$scope-$label-$value-${available.keys.join(',')}'),
      initialValue: value ?? '',
      isExpanded: true,
      decoration: InputDecoration(
          labelText: label,
          helperText: scope != 'defaults' && value == null
              ? 'Inherited: ${inherited == null ? 'Automatic' : choices[inherited] ?? _title(inherited)}'
              : null),
      items: [
        const DropdownMenuItem(value: '', child: Text('Automatic')),
        for (final entry in available.entries)
          DropdownMenuItem(
              value: entry.key,
              enabled: choices.containsKey(entry.key),
              child: Text(entry.value, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: busy
          ? null
          : (id) => setState(() {
                error = null;
                changed(id == '' ? null : id);
              }),
    );
  }

  Widget _notice(String text, {bool error = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(text,
          style: TextStyle(
              color: error
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurfaceVariant)));
  String _summary(
          AxWorkflowSelection value, AxWorkflowSelectionOptions options) =>
      [
        if (value.worker != null)
          options.worker(value.worker)?.displayName ?? 'Unavailable Worker',
        if (value.model != null)
          options.models(value.worker)[value.model] ?? value.model!,
        if (value.effort != null) '${_title(value.effort!)} effort',
      ].join(' · ');
}

String _availability(AxWorker worker) =>
    worker.readinessState == 'offline' || worker.status == 'offline'
        ? 'Offline'
        : 'Unavailable';
String _title(String value) =>
    value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';
