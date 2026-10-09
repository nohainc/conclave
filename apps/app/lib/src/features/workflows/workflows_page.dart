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
    unawaited(widget.configurations
        .ensureDefault()
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
        widget.configurations.refreshDefault(),
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
            engine: widget.configurations.engine,
            query: widget.configurations.defaultQuery,
            ensure: false,
            builder: (context, defaultState) => AxQueryBuilder(
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
                        if (widget.configurations.spaceId != null &&
                            workspaceState.hasData)
                          IconButton(
                              key: const ValueKey('reset-global-workflows'),
                              tooltip: 'Reset workflows to global settings',
                              onPressed: widget.canEdit && !_changingWorkspace
                                  ? () => _selectWorkspace(
                                      null, workspaceState.data!,
                                      inherit: true)
                                  : null,
                              icon: const Icon(Icons.settings_backup_restore)),
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
                        LayoutBuilder(builder: (context, constraints) {
                          final workspacePicker = KeyedSubtree(
                              key: ValueKey(_workspacePickerRevision),
                              child: DropdownButtonFormField<String>(
                                  key: const ValueKey('workflow-workspace'),
                                  initialValue:
                                      workspaceState.data!.workspaceId ?? '',
                                  decoration: const InputDecoration(
                                      labelText: 'Workspace'),
                                  items: [
                                    const DropdownMenuItem(
                                        value: '',
                                        child: Text('Select a Workspace')),
                                    for (final workspace
                                        in workspaceState.data!.workspaces)
                                      DropdownMenuItem(
                                          value: workspace.id,
                                          child: Text(workspace.name)),
                                    if (workspaceState.data!.workspaceId !=
                                            null &&
                                        !workspaceState.data!.workspaces.any(
                                            (w) =>
                                                w.id ==
                                                workspaceState
                                                    .data!.workspaceId))
                                      DropdownMenuItem(
                                          value:
                                              workspaceState.data!.workspaceId,
                                          child: const Text(
                                              'Unavailable Workspace')),
                                  ],
                                  onChanged:
                                      widget.canEdit && !_changingWorkspace
                                          ? (id) => _selectWorkspace(
                                              id == '' ? null : id,
                                              workspaceState.data!)
                                          : null));
                          final defaultPicker =
                              workflows.isNotEmpty && preferences.data != null
                                  ? _defaultPicker(
                                      context,
                                      defaultState,
                                      workflows,
                                      preferences.data!,
                                      workspaceState.data!.workspaceId != null)
                                  : const SizedBox.shrink();
                          final inline = constraints.maxWidth >= 760;
                          return Column(children: [
                            if (inline)
                              Row(children: [
                                Expanded(child: workspacePicker),
                                const SizedBox(width: 12),
                                Expanded(child: defaultPicker),
                              ])
                            else ...[
                              workspacePicker,
                              const SizedBox(height: 16),
                              defaultPicker,
                            ],
                          ]);
                        }),
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
                                    color:
                                        Theme.of(context).colorScheme.error))),
                      const SizedBox(height: 18),
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
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final cards = [
                              for (final definition in workflows.values)
                                _card(
                                    definition,
                                    _configuration(
                                        preferences.data!, definition.id),
                                    workers,
                                    workspaceState.data?.workspaceId != null,
                                    defaultState.data == definition.id &&
                                        workspaceState.data?.workspaceId !=
                                            null &&
                                        (definition.id == 'chat' ||
                                            _configuration(preferences.data!,
                                                    definition.id)
                                                .enabled)),
                            ];
                            final twoColumns = constraints.maxWidth >= 760;
                            final width = twoColumns
                                ? (constraints.maxWidth - 12) / 2
                                : constraints.maxWidth;
                            return Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                for (final card in cards)
                                  SizedBox(width: width, child: card),
                              ],
                            );
                          },
                        ),
                    ]);
              },
            ),
          ),
        ),
      );
  Widget _defaultPicker(
      BuildContext context,
      AxQueryState<String> state,
      Map<String, AxBuiltinWorkflow> workflows,
      List<AxUserWorkflowConfiguration> configurations,
      bool hasWorkspace) {
    final enabled = workflows.values
        .where((definition) =>
            _configuration(configurations, definition.id).enabled ||
            definition.id == 'chat')
        .toList();
    final selected = enabled.any((definition) => definition.id == state.data)
        ? state.data
        : (enabled.any((definition) => definition.id == 'chat')
            ? 'chat'
            : enabled.firstOrNull?.id);
    return DropdownButtonFormField<String>(
        key: const ValueKey('workflow-default'),
        initialValue: selected ?? '',
        decoration: const InputDecoration(labelText: 'Default workflow'),
        items: [
          for (final definition in enabled)
            DropdownMenuItem(
                value: definition.id, child: Text(definition.name)),
        ],
        onChanged: widget.canEdit && hasWorkspace && !state.isFetching
            ? (id) async {
                if (id == null || id.isEmpty || id == selected) return;
                try {
                  await widget.configurations.setDefault(id);
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(error.toString())));
                  }
                }
              }
            : null);
  }

  AxUserWorkflowConfiguration _configuration(
          List<AxUserWorkflowConfiguration> values, String id) =>
      values.firstWhere((value) => value.workflowId == id,
          orElse: () => AxUserWorkflowConfiguration(workflowId: id));
  Widget _card(
      AxBuiltinWorkflow definition,
      AxUserWorkflowConfiguration configuration,
      List<AxWorker> workers,
      bool hasWorkspace,
      bool isDefault) {
    final selection = definition.steps.length == 1
        ? configuration.selectionFor(definition.steps.first.kind)
        : configuration.defaults;
    final summary = <(String, String)>[
      ('Worker', _workerName(selection.worker, workers)),
      ('Model', _modelName(selection.model, selection.worker, workers)),
      ('Effort', _label(selection.effort)),
    ];
    final colors = Theme.of(context).colorScheme;
    final unresolvedWorker = definition.steps.any((step) {
      final workerId = configuration.selectionFor(step.kind).worker;
      return workerId == null ||
          !workers.any((worker) => worker.id == workerId);
    });
    final status = !hasWorkspace
        ? 'Select a Workspace'
        : definition.id != 'chat' && !configuration.enabled
            ? 'Disabled'
            : unresolvedWorker
                ? 'Select a Worker'
                : null;
    return Opacity(
        opacity: hasWorkspace ? 1 : 0.58,
        child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 210),
            child: Card(
                key: ValueKey('workflow-${definition.id}'),
                margin: EdgeInsets.zero,
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
                                          ?.copyWith(
                                              fontWeight: FontWeight.w700))),
                              if (isDefault)
                                Container(
                                    key: ValueKey(
                                        'workflow-default-${definition.id}'),
                                    margin: const EdgeInsets.only(right: 6),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                        color: colors.primaryContainer,
                                        borderRadius:
                                            BorderRadius.circular(999)),
                                    child: Text('Default',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                                color:
                                                    colors.onPrimaryContainer,
                                                fontWeight: FontWeight.w700))),
                              if (status != null)
                                Container(
                                    key: ValueKey(
                                        'workflow-status-${definition.id}'),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                        color: !hasWorkspace || unresolvedWorker
                                            ? colors.errorContainer
                                            : colors.surfaceContainerHighest,
                                        borderRadius:
                                            BorderRadius.circular(999)),
                                    child: Text(status,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                                color: !hasWorkspace ||
                                                        unresolvedWorker
                                                    ? colors.onErrorContainer
                                                    : colors.onSurfaceVariant,
                                                fontWeight: FontWeight.w700)))
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
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
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
                          ]),
                    )))));
  }

  Future<void> _selectWorkspace(
      String? workspaceId, AxWorkflowWorkspaceSettings current,
      {bool inherit = false}) async {
    if (workspaceId == current.workspaceId &&
        inherit == current.inherited &&
        !(inherit && widget.configurations.spaceId != null)) {
      return;
    }
    if (_changingWorkspace) return;
    setState(() => _changingWorkspace = true);
    try {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: Text(
                      inherit ? 'Reset Space workflows?' : 'Change Workspace?'),
                  content: Text(inherit
                      ? 'This will discard this Space’s workflow settings and use the global user workflow settings. Existing runs will keep their recorded settings.'
                      : 'All workflows will reset with explicit Worker selections, Auto model and effort defaults, and inherited steps. Existing runs will keep their recorded settings.${widget.configurations.spaceId == null ? ' Spaces using the global Workspace will also reset.' : ' The selected Workspace will be authorized to execute Work in this Space.'}'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(
                            inherit ? 'Reset workflows' : 'Change and reset'))
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

String _label(String? value) =>
    value == null ? 'Auto' : '${value[0].toUpperCase()}${value.substring(1)}';
String _workerName(String? id, List<AxWorker> workers) {
  if (id == null) return 'Select Worker...';
  for (final worker in workers) {
    if (worker.id == id) {
      return '${worker.displayName}${worker.isReady ? '' : ' · Unavailable'}';
    }
  }
  return '$id · Unavailable';
}

String _modelName(String? id, String? workerId, List<AxWorker> workers) {
  if (id == null) return 'Auto';
  for (final worker
      in workers.where((worker) => workerId == null || worker.id == workerId)) {
    for (final model
        in worker.executionOptions?.models ?? const <AxWorkerModelOption>[]) {
      if (model.id == id) return model.name;
    }
  }
  return id;
}
