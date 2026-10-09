import 'dart:async';
import 'package:flutter/material.dart';
import '../../ax/ax_models.dart';
import '../../ax/ax_workflow_configuration.dart';
import '../../ax/sync/ax_session_catalogs.dart';
import '../../ax/sync/ax_workflow_configurations.dart';
import '../../ax/sync/ax_query_builder.dart';
import '../../ax/sync/ax_sync_engine.dart';
import 'workflow_editor.dart';

class WorkflowsPage extends StatefulWidget {
  const WorkflowsPage(
      {super.key,
      required this.catalogs,
      required this.configurations,
      this.canEdit = true});
  final bool canEdit;
  final AxSessionCatalogs catalogs;
  final AxWorkflowConfigurations configurations;
  @override
  State<WorkflowsPage> createState() => _WorkflowsPageState();
}

class _WorkflowsPageState extends State<WorkflowsPage> {
  int _workspacePickerRevision = 0;
  bool _changingWorkspace = false;
  @override
  void initState() {
    super.initState();
    _ensure();
  }

  @override
  void didUpdateWidget(WorkflowsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.configurations != widget.configurations ||
        oldWidget.catalogs != widget.catalogs) {
      _ensure();
    }
  }

  void _ensure() {
    unawaited(widget.configurations
        .ensureWorkspace()
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    unawaited(widget.configurations
        .ensure()
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    unawaited(widget.catalogs.engine
        .ensure(widget.catalogs.workflows, policy: AxCachePolicy.cacheFirst)
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    unawaited(widget.catalogs
        .ensureWorkers()
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  Future<void> _refresh() async {
    try {
      await Future.wait([
        widget.configurations.refresh(),
        widget.configurations.engine
            .refresh(widget.configurations.workspaceQuery),
        widget.catalogs.engine.refresh(widget.catalogs.workflows),
        widget.catalogs.refreshWorkers(),
      ]);
    } catch (_) {/* Errors are shown by the resource queries. */}
  }

  @override
  Widget build(BuildContext context) => AxQueryBuilder(
        engine: widget.configurations.engine,
        query: widget.configurations.workspaceQuery,
        ensure: false,
        builder: (context, workspaceState) =>
            _buildPage(context, workspaceState),
      );
  Widget _buildPage(BuildContext context,
          AxQueryState<AxWorkflowWorkspaceSettings> workspaceState) =>
      AxQueryBuilder(
        engine: widget.catalogs.engine,
        query: widget.catalogs.workflows,
        ensure: false,
        builder: (context, definitions) => AxQueryBuilder(
          engine: widget.configurations.engine,
          query: widget.configurations.query,
          ensure: false,
          builder: (context, preferences) => AxQueryBuilder(
            engine: widget.catalogs.engine,
            query: widget.catalogs.workers,
            ensure: false,
            builder: (context, inventory) {
              final workflows = <String, AxBuiltinWorkflow>{};
              for (final definition
                  in definitions.data ?? const <AxBuiltinWorkflow>[]) {
                if ((workflows[definition.id]?.version ?? 0) <
                    definition.version) {
                  workflows[definition.id] = definition;
                }
              }
              final workers = (inventory.data ?? const <AxWorker>[])
                  .where((worker) =>
                      worker.workspaceId == workspaceState.data?.workspaceId)
                  .toList();
              return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Expanded(
                          child: Text('Workflows',
                              style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.3))),
                      IconButton(
                          tooltip: 'Refresh workflows',
                          onPressed: definitions.isFetching ||
                                  preferences.isFetching ||
                                  inventory.isFetching
                              ? null
                              : _refresh,
                          icon: const Icon(Icons.refresh)),
                    ]),
                    Text(
                        widget.configurations.spaceId == null
                            ? 'Configure how Conclave performs tasks by default.'
                            : 'All Threads use these workflows. Start with global defaults; customize them for this Space.',
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                    const SizedBox(height: 18),
                    if (workspaceState.hasData) ...[
                      KeyedSubtree(
                          key: ValueKey(_workspacePickerRevision),
                          child: DropdownButtonFormField<String>(
                              key: const ValueKey('workflow-workspace'),
                              initialValue:
                                  workspaceState.data!.workspaceId ?? '',
                              decoration:
                                  const InputDecoration(labelText: 'Workspace'),
                              items: [
                                const DropdownMenuItem(
                                    value: '',
                                    child: Text('Select a Workspace')),
                                for (final workspace
                                    in workspaceState.data!.workspaces)
                                  DropdownMenuItem(
                                      value: workspace.id,
                                      child: Text(workspace.name)),
                                if (workspaceState.data!.workspaceId != null &&
                                    !workspaceState.data!.workspaces.any((w) =>
                                        w.id ==
                                        workspaceState.data!.workspaceId))
                                  DropdownMenuItem(
                                      value: workspaceState.data!.workspaceId,
                                      child:
                                          const Text('Unavailable Workspace')),
                              ],
                              onChanged: widget.canEdit && !_changingWorkspace
                                  ? (id) => _selectWorkspace(
                                      id == '' ? null : id,
                                      workspaceState.data!)
                                  : null)),
                      if (workspaceState.data!.inherited)
                        const Text('Using the global Workspace.'),
                      if (widget.canEdit &&
                          widget.configurations.spaceId != null &&
                          !workspaceState.data!.inherited)
                        TextButton(
                            onPressed: _changingWorkspace
                                ? null
                                : () => _selectWorkspace(
                                    null, workspaceState.data!,
                                    inherit: true),
                            child: const Text('Use global Workspace')),
                      const SizedBox(height: 16),
                    ] else if (workspaceState.error != null)
                      const Text(
                          'Workspace settings could not be loaded. Refresh to retry.'),
                    if (definitions.error != null ||
                        preferences.error != null ||
                        inventory.error != null)
                      Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                              'Some workflow data could not be loaded. Refresh to try again.',
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error))),
                    if (!definitions.hasData || !preferences.hasData)
                      if (definitions.isFetching || preferences.isFetching)
                        const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: CircularProgressIndicator()))
                      else
                        const Text('Workflow configuration is unavailable.')
                    else if (workflows.isEmpty)
                      const Text('No workflows are available.')
                    else
                      for (final definition in workflows.values)
                        _card(
                            definition,
                            _configuration(preferences.data!, definition.id),
                            workers,
                            workspaceState.data?.workspaceId != null),
                  ]);
            },
          ),
        ),
      );
  AxUserWorkflowConfiguration _configuration(
          List<AxUserWorkflowConfiguration> values, String id) =>
      values.firstWhere((value) => value.workflowId == id,
          orElse: () => AxUserWorkflowConfiguration(workflowId: id));
  Widget _card(
      AxBuiltinWorkflow definition,
      AxUserWorkflowConfiguration configuration,
      List<AxWorker> workers,
      bool hasWorkspace) {
    final selection = definition.steps.length == 1
        ? configuration.selectionFor(definition.steps.first.kind)
        : configuration.defaults;
    final summary = <(String, String)>[
      ('Worker', _workerName(selection.worker, workers)),
      ('Model', _modelName(selection.model, selection.worker, workers)),
      ('Effort', _label(selection.effort)),
    ];
    return Card(
        key: ValueKey('workflow-${definition.id}'),
        margin: const EdgeInsets.only(bottom: 12),
        child: InkWell(
            key: ValueKey('open-workflow-${definition.id}'),
            onTap: widget.canEdit && hasWorkspace && !_changingWorkspace
                ? () => _edit(definition, configuration)
                : null,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                          child: Text(definition.name,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700))),
                      if (!configuration.enabled) const Text('Disabled')
                    ]),
                    const SizedBox(height: 4),
                    Text(definition.description,
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                    if (definition.steps.length > 1) ...[
                      const SizedBox(height: 8),
                      Text(
                          '${definition.steps.length} steps${configuration.stepOverrides.isEmpty ? '' : ' · ${configuration.stepOverrides.length} step overrides'}'),
                    ],
                    const SizedBox(height: 14),
                    for (final row in summary)
                      Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                    width: 76,
                                    child: Text(row.$1,
                                        style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant))),
                                Expanded(child: Text(row.$2)),
                              ])),
                    Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          key: ValueKey('edit-${definition.id}'),
                          onPressed: widget.canEdit &&
                                  hasWorkspace &&
                                  !_changingWorkspace
                              ? () => _edit(definition, configuration)
                              : null,
                          label: const Text('Edit'),
                          icon: const Icon(Icons.arrow_forward, size: 16),
                          iconAlignment: IconAlignment.end,
                        )),
                  ]),
            )));
  }

  Future<void> _selectWorkspace(
      String? workspaceId, AxWorkflowWorkspaceSettings current,
      {bool inherit = false}) async {
    if (workspaceId == current.workspaceId && inherit == current.inherited) {
      return;
    }
    if (_changingWorkspace) return;
    setState(() => _changingWorkspace = true);
    try {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('Change Workspace?'),
                  content: Text(
                      '${inherit ? 'All Space workflows will return to the current global settings.' : 'All workflows will reset to enabled with Automatic Worker, model, effort, and inherited steps.'} Existing runs will keep their recorded settings.${widget.configurations.spaceId == null ? ' Spaces using the global Workspace will also reset.' : ' The selected Workspace will be authorized to execute Work in this Space.'}'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Change and reset'))
                  ]));
      if (confirmed != true || !mounted) return;
      await widget.configurations
          .selectWorkspace(workspaceId, inherit: inherit);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) {
        setState(() {
          _changingWorkspace = false;
          _workspacePickerRevision++;
        });
      }
    }
  }

  Future<void> _edit(AxBuiltinWorkflow definition,
      AxUserWorkflowConfiguration configuration) async {
    await showDialog<void>(
        context: context,
        builder: (context) => WorkflowEditor(
              definition: definition,
              configuration: configuration,
              catalogs: widget.catalogs,
              workspaceId: widget.configurations.engine
                  .peek(widget.configurations.workspaceQuery)
                  .data
                  ?.workspaceId,
              cache: widget.configurations,
            ));
  }
}

String _label(String? value) => value == null
    ? 'Automatic'
    : '${value[0].toUpperCase()}${value.substring(1)}';
String _workerName(String? id, List<AxWorker> workers) {
  if (id == null) return 'Automatic';
  for (final worker in workers) {
    if (worker.id == id) {
      return '${worker.displayName}${worker.isReady ? '' : ' · Unavailable'}';
    }
  }
  return '$id · Unavailable';
}

String _modelName(String? id, String? workerId, List<AxWorker> workers) {
  if (id == null) return 'Automatic';
  for (final worker
      in workers.where((worker) => workerId == null || worker.id == workerId)) {
    for (final model
        in worker.executionOptions?.models ?? const <AxWorkerModelOption>[]) {
      if (model.id == id) return model.name;
    }
  }
  return id;
}
