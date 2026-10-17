import 'dart:async';
import '../common/quiet_notices.dart';
import 'package:flutter/material.dart';
import '../../ax/ax_models.dart';
import '../../ax/ax_workflow_configuration.dart';
import '../../ax/sync/ax_session_catalogs.dart';
import '../../ax/sync/ax_workflow_configurations.dart';
import '../../ax/sync/ax_query_builder.dart';
import '../../ax/sync/ax_sync_engine.dart';
import 'workflow_editor.dart';
import 'workflow_visibility.dart';

class WorkflowsPage extends StatefulWidget {
  const WorkflowsPage(
      {super.key,
      required this.catalogs,
      required this.configurations,
      this.viewerEmail,
      required this.workspaceId,
      this.canEdit = true});
  final bool canEdit;

  /// The Workspace whose workflows this section edits, shown in its tab.
  /// [configurations] must be scoped to the same Workspace
  /// (`AxWorkflowConfigurations.forWorkspace`). Whether the Workspace is the
  /// one new Work runs on is shown and changed here.
  final String workspaceId;
  final AxSessionCatalogs catalogs;
  final AxWorkflowConfigurations configurations;
  final String? viewerEmail;
  @override
  State<WorkflowsPage> createState() => _WorkflowsPageState();
}

class _WorkflowsPageState extends State<WorkflowsPage> {
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
                for (final definition in visibleWorkflowDefinitions(
                    definitions.data ?? const <AxBuiltinWorkflow>[],
                    viewerEmail: widget.viewerEmail)) {
                  if ((workflows[definition.id]?.version ?? 0) <
                      definition.version) {
                    workflows[definition.id] = definition;
                  }
                }
                final workers = (inventory.data ?? const <AxWorker>[])
                    .where((worker) => worker.workspaceId == widget.workspaceId)
                    .toList();
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text('Workflows',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700))),
                        IconButton(
                            tooltip: 'Refresh workflows',
                            onPressed: definitions.isFetching ||
                                    preferences.isFetching ||
                                    inventory.isFetching
                                ? null
                                : _refresh,
                            icon: const Icon(Icons.refresh)),
                      ]),
                      if (workspaceState.hasData) ...[
                        _activeRow(context, workspaceState.data!),
                        if (workflows.isNotEmpty &&
                            preferences.data != null) ...[
                          const SizedBox(height: 12),
                          _defaultPicker(context, defaultState, workflows,
                              preferences.data!),
                        ],
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
                                    defaultState.data == definition.id &&
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
      List<AxUserWorkflowConfiguration> configurations) {
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
        onChanged: widget.canEdit && !state.isFetching
            ? (id) async {
                if (id == null || id.isEmpty || id == selected) return;
                try {
                  await widget.configurations.setDefault(id);
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showNotice(SnackBar(content: Text(error.toString())));
                  }
                }
              }
            : null);
  }

  /// Embedded tab header: whether new Work runs on this Workspace, or a way to
  /// make it so.
  Widget _activeRow(
      BuildContext context, AxWorkflowWorkspaceSettings settings) {
    final active = settings.workspaceId == widget.workspaceId;
    final colors = Theme.of(context).colorScheme;
    return Row(children: [
      Expanded(
          child: Text(
              active
                  ? 'New Work runs on this Workspace and uses these workflows.'
                  : 'New Work runs on another Workspace. These workflows apply once this one is in use.',
              style: TextStyle(color: colors.onSurfaceVariant))),
      if (active)
        Container(
            key: const ValueKey('workspace-workflows-active'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(999)),
            child: Text('Active',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onPrimaryContainer,
                    fontWeight: FontWeight.w700)))
      else
        OutlinedButton(
            key: const ValueKey('use-workspace-for-workflows'),
            onPressed: widget.canEdit && !_changingWorkspace
                ? () => _selectWorkspace(settings)
                : null,
            child: const Text('Use this Workspace')),
    ]);
  }

  AxUserWorkflowConfiguration _configuration(
          List<AxUserWorkflowConfiguration> values, String id) =>
      values.firstWhere((value) => value.workflowId == id,
          orElse: () => AxUserWorkflowConfiguration(workflowId: id));
  Widget _card(
      AxBuiltinWorkflow definition,
      AxUserWorkflowConfiguration configuration,
      List<AxWorker> workers,
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
    final status = definition.id != 'chat' && !configuration.enabled
        ? 'Disabled'
        : unresolvedWorker
            ? 'Select a Worker'
            : null;
    return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 210),
        child: Card(
            key: ValueKey('workflow-${definition.id}'),
            margin: EdgeInsets.zero,
            child: InkWell(
                key: ValueKey('open-workflow-${definition.id}'),
                onTap: widget.canEdit && !_changingWorkspace
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
                          if (isDefault)
                            Container(
                                key: ValueKey(
                                    'workflow-default-${definition.id}'),
                                margin: const EdgeInsets.only(right: 6),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                    color: colors.primaryContainer,
                                    borderRadius: BorderRadius.circular(999)),
                                child: Text('Default',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                            color: colors.onPrimaryContainer,
                                            fontWeight: FontWeight.w700))),
                          if (status != null)
                            Container(
                                key: ValueKey(
                                    'workflow-status-${definition.id}'),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                    color: unresolvedWorker
                                        ? colors.errorContainer
                                        : colors.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(999)),
                                child: Text(status,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                            color: unresolvedWorker
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
                      ]),
                ))));
  }

  /// Makes this Workspace the one new Work runs on. Workflow settings are kept
  /// per Workspace, so nothing of the other Workspaces is lost.
  Future<void> _selectWorkspace(AxWorkflowWorkspaceSettings current) async {
    if (widget.workspaceId == current.workspaceId || _changingWorkspace) return;
    setState(() => _changingWorkspace = true);
    try {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('Use this Workspace?'),
                  content: const Text(
                      'New Work will run on this Workspace using its own workflow settings. Workflow settings of other Workspaces are kept. Workflow overrides of Spaces using the global Workspace are reset, and existing runs keep their recorded settings.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Use Workspace'))
                  ]));
      if (confirmed != true || !mounted) return;
      await widget.configurations.selectWorkspace(widget.workspaceId);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showNotice(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _changingWorkspace = false);
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
              workspaceId: widget.workspaceId,
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
