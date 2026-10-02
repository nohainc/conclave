part of '../projects_pages.dart';

class WorkstreamPage extends StatefulWidget {
  const WorkstreamPage({
    super.key,
    required this.project,
    required this.workstream,
    this.dataSource,
    this.currentUserId,
    required this.onBackToProject,
    required this.onArchive,
    this.onRename,
    this.onRunWork,
    this.realtimeEvents,
    this.initialTab = 0,
  });

  final AxProject project;
  final AxWorkstream workstream;
  final AxDataSource? dataSource;
  final String? currentUserId;
  final VoidCallback onBackToProject;
  final VoidCallback onArchive;
  final Future<void> Function(String name)? onRename;
  final Future<String> Function(String prompt, String workflowId,
      List<Map<String, dynamic>> attachments)? onRunWork;
  final Stream<Map<String, dynamic>>? realtimeEvents;
  final int initialTab;

  @override
  State<WorkstreamPage> createState() => _WorkstreamPageState();
}

class _WorkstreamPageState extends State<WorkstreamPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _requestController = TextEditingController();
  final _discussionController = TextEditingController();
  late final TextEditingController _workstreamInstructionsController;
  String _workflow = '';
  List<AxBuiltinWorkflow> _workflowCatalog = const [];
  bool _loadingWorkflows = true;
  String? _workflowCatalogError;
  final List<_DiscussionItem> _discussion = [];
  List<AxWorkRequest> _workTimeline = const [];
  bool _loadingWorkTimeline = true;
  bool _refreshingWorkTimeline = false;
  bool _workTimelineRefreshPending = false;
  String? _workTimelineError;
  String? _workSubmitError;
  StreamSubscription<Map<String, dynamic>>? _workEventSubscription;
  bool _submittingWork = false;
  List<Map<String, dynamic>> _workAttachments = [];
  List<AxWorker> _projectWorkers = const [];
  List<AxWorker> _eligibleWorkers = const [];
  Map<String, String> _projectWorkspaceNames = const {};
  late Map<String, dynamic> _workConfig;
  bool _loadingWorkChoices = true;
  bool _savingWorkConfig = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      initialIndex: widget.initialTab.clamp(0, 2),
      vsync: this,
    );
    _workConfig = Map<String, dynamic>.from(widget.workstream.workConfig);
    _workstreamInstructionsController = TextEditingController(
      text: _workConfig['workstreamInstructions']?.toString() ?? '',
    );
    _loadDiscussion();
    _refreshWorkTimeline();
    _subscribeToWorkEvents();
    _loadWorkChoices();
    _loadWorkflowCatalog();
  }

  Future<void> _loadWorkflowCatalog() async {
    final ds = widget.dataSource;
    if (ds == null) {
      setState(() {
        _loadingWorkflows = false;
        _workflowCatalogError = 'Workflow catalog is unavailable.';
      });
      return;
    }
    try {
      final workflows = await ds.loadBuiltinWorkflowCatalog();
      if (!mounted) return;
      setState(() {
        _workflowCatalog = workflows;
        _loadingWorkflows = false;
        _workflowCatalogError =
            workflows.isEmpty ? 'No built-in Workflows are available.' : null;
        _workflow =
            workflows.isEmpty ? '' : _workstreamDefaultReference(workflows);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingWorkflows = false;
        _workflowCatalogError = 'Could not load the Workflow catalog.';
      });
    }
  }

  String _workstreamDefaultReference(List<AxBuiltinWorkflow> workflows) {
    if (workflows.isEmpty) return '';
    final defaultId = _workConfig['defaultWorkflowId']?.toString();
    return workflows
            .where((workflow) => workflow.id == defaultId)
            .map((workflow) => workflow.reference)
            .firstOrNull ??
        workflows.first.reference;
  }

  Future<void> _loadWorkChoices() async {
    final ds = widget.dataSource;
    if (ds == null) {
      setState(() => _loadingWorkChoices = false);
      return;
    }
    try {
      final loaded = await Future.wait([
        ds.loadWorkspaceWorkerInventory(),
        ds.loadProjectWorkspaces(projectId: widget.project.id),
      ]);
      if (!mounted) return;
      final grants = loaded[1] as List<Map<String, dynamic>>;
      final names = <String, String>{};
      for (final grant in grants) {
        final id = (grant['workspaceId'] ?? grant['id'] ?? '').toString();
        if (id.isEmpty) continue;
        names[id] = (grant['workspaceName'] ?? grant['name'] ?? id).toString();
      }
      setState(() {
        _projectWorkers = (loaded[0] as List<AxWorker>)
            .where((worker) => names.containsKey(worker.workspaceId))
            .toList();
        _eligibleWorkers = _projectWorkers
            .where((worker) =>
                worker.activationState == 'enabled' &&
                worker.readinessState == 'ready')
            .toList();
        _projectWorkspaceNames = names;
        _loadingWorkChoices = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingWorkChoices = false);
    }
  }

  Future<void> _loadDiscussion() async {
    final ds = widget.dataSource;
    if (ds == null) return;
    try {
      final messages =
          await ds.loadDiscussionMessages(workstreamId: widget.workstream.id);
      if (!mounted) return;
      setState(() {
        _discussion
          ..clear()
          ..addAll(messages.map((m) {
            final dt = DateTime.tryParse(m.createdAt)?.toLocal();
            final timeStr = dt != null
                ? '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}'
                : null;
            final isMe = widget.currentUserId != null &&
                widget.currentUserId!.isNotEmpty &&
                m.authorUserId == widget.currentUserId;
            return _DiscussionItem(
              id: m.id,
              author: isMe ? 'You' : (m.authorName ?? 'Member'),
              text: m.body,
              sentAt: timeStr,
              isMe: isMe,
            );
          }));
      });
    } catch (_) {
      // Ignore network errors on initial load
    }
  }

  @override
  void didUpdateWidget(WorkstreamPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      _tabController.animateTo(widget.initialTab.clamp(0, 2));
    }
    if (oldWidget.workstream.workConfig != widget.workstream.workConfig) {
      _workConfig = Map<String, dynamic>.from(widget.workstream.workConfig);
      _workstreamInstructionsController.text =
          _workConfig['workstreamInstructions']?.toString() ?? '';
      if (_workflowCatalog.isNotEmpty) {
        _workflow = _workstreamDefaultReference(_workflowCatalog);
      }
    }
    if (oldWidget.realtimeEvents != widget.realtimeEvents) {
      _workEventSubscription?.cancel();
      _subscribeToWorkEvents();
    }
  }

  void _subscribeToWorkEvents() {
    _workEventSubscription = widget.realtimeEvents?.listen((event) {
      final type = event['type'];
      if (type == 'reconnect.required') {
        unawaited(_refreshWorkTimeline());
        return;
      }
      if (type is! String ||
          !(type.startsWith('work_request.') || type.startsWith('step.'))) {
        return;
      }
      final payload = event['payload'];
      if (payload is! Map || payload['workstreamId'] != widget.workstream.id) {
        return;
      }
      unawaited(_refreshWorkTimeline(activeOnly: true));
    });
  }

  bool get _canExecute =>
      widget.project.role == 'owner' || widget.workstream.canExecuteWork;
  bool get _canConfigureWork =>
      widget.project.role == 'owner' || widget.workstream.canConfigureWork;

  @override
  void dispose() {
    _workEventSubscription?.cancel();
    _tabController.dispose();
    _requestController.dispose();
    _discussionController.dispose();
    _workstreamInstructionsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _tabController,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                tabAlignment: TabAlignment.center,
                tabs: const [
                  Tab(text: 'Discuss'),
                  Tab(text: 'Work'),
                  Tab(text: 'Work settings'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_tabController.index == 0)
              _discuss(context)
            else if (_tabController.index == 1)
              _work(context),
            if (_tabController.index == 2) _workConfigView(),
          ],
        ),
      );

  Widget _discuss(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_discussion.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
            alignment: Alignment.center,
            child: Column(
              children: [
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 42,
                  color: isDark ? Colors.white24 : Colors.black26,
                ),
                const SizedBox(height: 12),
                Text(
                  'No discussion messages yet',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Share context, decisions, or questions with your team below.',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ),
              ],
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _discussion.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final message = _discussion[index];
              return _DiscussionMessageBubble(
                key: ValueKey(message.id),
                item: message,
                onCopy: () {
                  Clipboard.setData(ClipboardData(text: message.text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Message copied to clipboard'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                onEdit: (newText) => _editDiscussion(message.id, newText),
              );
            },
          ),
        const SizedBox(height: 16),
        _DiscussionInputBox(
          controller: _discussionController,
          onSend: _sendDiscussion,
        ),
      ],
    );
  }

  Widget _work(BuildContext context) => _WorkComposer(
        requestController: _requestController,
        workflow: _workflow,
        workflowCatalog: _workflowCatalog,
        loadingWorkflows: _loadingWorkflows,
        workflowCatalogError: _workflowCatalogError,
        canExecute: _canExecute,
        workTimeline: _workTimeline,
        loadingTimeline: _loadingWorkTimeline,
        timelineError: _workTimelineError,
        submitError: _workSubmitError,
        submitting: _submittingWork,
        attachments: _workAttachments,
        onAddFiles: _addWorkFiles,
        onAddReference: _addWorkReference,
        onRemoveAttachment: (index) => setState(() {
          _workAttachments.removeAt(index);
        }),
        onRefresh: _refreshWorkTimeline,
        onShowRunDetails: widget.dataSource == null ? null : _showRunDetails,
        onRetryStep: widget.dataSource == null ? null : _retryWorkRequestStep,
        onCancelRun:
            widget.dataSource == null ? null : _cancelFailedWorkRequest,
        onWorkflowChanged: (value) => setState(() => _workflow = value),
        onRun: _runWork,
      );

  Widget _workConfigView() {
    final bindings = _workConfig['bindings'] is Map
        ? Map<String, dynamic>.from(_workConfig['bindings'] as Map)
        : <String, dynamic>{};
    final defaultWorkflowId = _workConfig['defaultWorkflowId']?.toString() ??
        _workflowCatalog.firstOrNull?.id ??
        '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Work settings', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        Text('Default workflow', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (_loadingWorkflows)
          const LinearProgressIndicator()
        else if (_workflowCatalog.isNotEmpty)
          DropdownButtonFormField<String>(
            itemHeight: null,
            initialValue: defaultWorkflowId,
            decoration: const InputDecoration(labelText: 'Default Workflow'),
            items: _workflowCatalog
                .map((workflow) => DropdownMenuItem(
                      value: workflow.id,
                      child: _workflowOption(context, workflow),
                    ))
                .toList(),
            onChanged: !_canConfigureWork || _savingWorkConfig
                ? null
                : (value) {
                    if (value != null) {
                      setState(() => _workConfig = {
                            ..._workConfig,
                            'defaultWorkflowId': value,
                          });
                    }
                  },
          ),
        const SizedBox(height: 12),
        Text('Workers', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (_loadingWorkChoices)
          const LinearProgressIndicator()
        else ...[
          if (_projectWorkers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Connect a Workspace and create a ready logical Worker before assigning Steps.',
              ),
            )
          else if (_eligibleWorkers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No logical Workers are Ready yet. Check Profile readiness in Workspace.',
              ),
            ),
          ...const [
            'direct',
            'research',
            'plan',
            'implement',
            'test',
            'verify',
          ].map((bindingId) {
            final raw = bindings[bindingId];
            final binding = raw is Map
                ? Map<String, dynamic>.from(raw)
                : <String, dynamic>{};
            final localWorkerId = binding['workerId']?.toString() ?? '';
            final selectedId =
                _eligibleWorkers.any((worker) => worker.id == localWorkerId)
                    ? localWorkerId
                    : '';
            final selectedWorker = _projectWorkers
                .where((worker) => worker.id == localWorkerId)
                .firstOrNull;
            final status = selectedWorker == null
                ? (localWorkerId.isEmpty ? 'Not assigned' : 'Unavailable')
                : _workerReadinessLabel(selectedWorker);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                      width: 100, child: Text(_stepDisplayName(bindingId))),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: selectedId,
                      decoration: const InputDecoration(
                        labelText: 'Worker',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('Choose a Worker'),
                        ),
                        ..._eligibleWorkers.map((worker) => DropdownMenuItem(
                              value: worker.id,
                              child: Text(
                                '${_workerDisplayName(worker)} · ${_projectWorkspaceNames[worker.workspaceId] ?? worker.workspaceId}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            )),
                      ],
                      onChanged: !_canConfigureWork || _savingWorkConfig
                          ? null
                          : (value) => _setStepBinding(
                                bindingId,
                                value == null || value.isEmpty
                                    ? <String, dynamic>{}
                                    : {...binding, 'workerId': value},
                              ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 110,
                    child: Text(
                      status,
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: status == 'Ready'
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.error,
                          ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
        const SizedBox(height: 12),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Advanced'),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Project instructions',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(widget.project.instructions.trim().isEmpty
                  ? 'None set'
                  : widget.project.instructions),
            ),
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Edit these in Project settings.'),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _workstreamInstructionsController,
              minLines: 2,
              maxLines: 5,
              maxLength: 4000,
              enabled: _canConfigureWork && !_savingWorkConfig,
              decoration: const InputDecoration(
                labelText: 'Workstream instructions',
                helperText: 'Applied to every Step.',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _workConfig = {
                    ..._workConfig,
                    'workstreamInstructions': value,
                  }),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Step settings',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            ...const [
              'direct',
              'research',
              'plan',
              'implement',
              'test',
              'verify',
            ].map((bindingId) {
              final raw = bindings[bindingId];
              final binding = raw is Map
                  ? Map<String, dynamic>.from(raw)
                  : <String, dynamic>{};
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_stepDisplayName(bindingId)),
                subtitle: Text(_stepAdvancedSummary(binding)),
                trailing: TextButton(
                  onPressed: !_canConfigureWork || _savingWorkConfig
                      ? null
                      : () => _editStepBinding(bindingId, binding),
                  child: const Text('Configure'),
                ),
              );
            }),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Concurrency'),
              subtitle: Text('Work Requests are queued for this Workstream.'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: !_canConfigureWork || _savingWorkConfig
              ? null
              : () => _saveWorkConfig(_workConfig),
          icon: _savingWorkConfig
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save_outlined),
          label: const Text('Save Work settings'),
        ),
        if (!_canConfigureWork)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
                'Only the Project owner or assigned Workstream lead can change Work settings.'),
          ),
      ],
    );
  }

  String _stepDisplayName(String bindingId) => switch (bindingId) {
        'direct' => 'Direct',
        'research' => 'Research',
        'plan' => 'Plan',
        'implement' => 'Implement',
        'test' => 'Test',
        _ => 'Verify',
      };

  String _workerReadinessLabel(AxWorker worker) {
    if (worker.activationState != 'enabled') return 'Disabled';
    if (worker.readinessState == 'ready') return 'Ready';
    if (worker.attentionReasonCode == 'sign_in_required' ||
        worker.readinessState == 'sign_in_required') {
      return 'Needs sign-in';
    }
    return 'Needs attention';
  }

  String _stepAdvancedSummary(Map<String, dynamic> binding) {
    final details = <String>[];
    if ((binding['additionalInstructions']?.toString().trim().isNotEmpty ??
        false)) {
      details.add('Step instructions');
    }
    if ((binding['model']?.toString().trim().isNotEmpty ?? false)) {
      details.add('Model: ${binding['model']}');
    }
    if ((binding['fallbackWorkerId']?.toString().trim().isNotEmpty ?? false)) {
      details.add('Fallback set');
    }
    return details.isEmpty
        ? 'Instructions, model, and fallback'
        : details.join(' · ');
  }

  void _setStepBinding(String bindingId, Map<String, dynamic> binding) {
    final bindings = _workConfig['bindings'] is Map
        ? Map<String, dynamic>.from(_workConfig['bindings'] as Map)
        : <String, dynamic>{};
    final cleaned = Map<String, dynamic>.from(binding)
      ..removeWhere((key, value) => value == null || value == '');
    if (cleaned.isEmpty) {
      bindings.remove(bindingId);
    } else {
      bindings[bindingId] = cleaned;
    }
    setState(() => _workConfig = {..._workConfig, 'bindings': bindings});
  }

  String _workerDisplayName(AxWorker worker) => switch (worker.workerTypeId) {
        'chatgpt' => 'ChatGPT',
        'gemini' => 'Gemini',
        _ => worker.workerTypeId,
      };

  Future<void> _editStepBinding(
    String bindingId,
    Map<String, dynamic> current,
  ) async {
    final modelController =
        TextEditingController(text: current['model']?.toString() ?? '');
    final instructionsController = TextEditingController(
      text: current['additionalInstructions']?.toString() ?? '',
    );
    final eligibleWorkerIds =
        _eligibleWorkers.map((worker) => worker.id).toSet();
    var selectedWorker = current['workerId']?.toString() ?? '';
    if (!eligibleWorkerIds.contains(selectedWorker)) selectedWorker = '';
    var fallbackWorker = current['fallbackWorkerId']?.toString() ?? '';
    if (!eligibleWorkerIds.contains(fallbackWorker) ||
        fallbackWorker == selectedWorker) {
      fallbackWorker = '';
    }
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('${_stepDisplayName(bindingId)} settings'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: fallbackWorker,
                    decoration: const InputDecoration(
                        labelText: 'Fallback Worker (optional)'),
                    items: [
                      const DropdownMenuItem(
                          value: '', child: Text('No fallback')),
                      ..._eligibleWorkers
                          .where((worker) => worker.id != selectedWorker)
                          .map((worker) => DropdownMenuItem(
                                value: worker.id,
                                child: Text(
                                    '${_workerDisplayName(worker)} · ${_projectWorkspaceNames[worker.workspaceId] ?? worker.workspaceId}'),
                              )),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => fallbackWorker = value ?? ''),
                  ),
                  TextField(
                    controller: modelController,
                    decoration:
                        const InputDecoration(labelText: 'Model (optional)'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: instructionsController,
                    minLines: 2,
                    maxLines: 5,
                    maxLength: 4000,
                    decoration: const InputDecoration(
                      labelText: 'Step instructions (optional)',
                      helperText:
                          'Added to this Step. Conclave manages its built-in guidance.',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext, true);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == true && mounted) {
      final binding = <String, dynamic>{
        if (selectedWorker.isNotEmpty) 'workerId': selectedWorker,
        if (fallbackWorker.isNotEmpty) 'fallbackWorkerId': fallbackWorker,
      };
      final model = modelController.text.trim();
      final instructions = instructionsController.text.trim();
      if (model.isNotEmpty) binding['model'] = model;
      if (instructions.isNotEmpty) {
        binding['additionalInstructions'] = instructions;
      }
      _setStepBinding(bindingId, binding);
    }
    modelController.dispose();
    instructionsController.dispose();
  }

  Future<void> _saveWorkConfig(Map<String, dynamic> config) async {
    if (!_canConfigureWork) return;
    final ds = widget.dataSource;
    if (ds == null) return;
    setState(() => _savingWorkConfig = true);
    try {
      final updated = await ds.updateWorkstream(
        workstreamId: widget.workstream.id,
        workConfig: config,
      );
      if (!mounted) return;
      setState(() {
        _workConfig = Map<String, dynamic>.from(updated.workConfig);
        _workstreamInstructionsController.text =
            _workConfig['workstreamInstructions']?.toString() ?? '';
        _savingWorkConfig = false;
      });
      final defaultId = _workConfig['defaultWorkflowId']?.toString();
      final selectedDefault = _workflowCatalog
          .where((workflow) => workflow.id == defaultId)
          .map((workflow) => workflow.reference)
          .firstOrNull;
      if (selectedDefault != null) _workflow = selectedDefault;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Work settings saved')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _savingWorkConfig = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save Work settings: $error')),
      );
    }
  }

  Future<void> _runWork() async {
    final text = _requestController.text;
    final requestText = text.trim().isEmpty
        ? 'Please use the attached inputs to complete the request.'
        : text;
    final submit = widget.onRunWork;
    final dataSource = widget.dataSource;
    if (!_canExecute ||
        (text.trim().isEmpty && _workAttachments.isEmpty) ||
        submit == null ||
        _submittingWork) {
      return;
    }
    setState(() {
      _submittingWork = true;
      _workSubmitError = null;
    });
    try {
      final workflowId = _workflow.split(':').first;
      if (dataSource != null) {
        final issues = await dataSource.validateWorkRequestEligibility(
          workstreamId: widget.workstream.id,
          workflowId: workflowId,
          attachments: _workAttachments,
        );
        if (issues.isNotEmpty) {
          final workflowName = _workflowCatalog
                  .where((definition) => definition.id == workflowId)
                  .map((definition) => definition.name)
                  .firstOrNull ??
              workflowId;
          if (mounted) {
            setState(() => _workSubmitError =
                'Cannot run $workflowName\n${issues.map((issue) => '• $issue').join('\n')}');
          }
          return;
        }
      }
      final workRequestId =
          await submit(requestText, workflowId, _workAttachments);
      if (!mounted) return;
      _requestController.clear();
      setState(() {
        _workAttachments = [];
        _workTimeline = [
          ..._workTimeline,
          AxWorkRequest(
            id: workRequestId,
            requestedByName: 'You',
            prompt: requestText,
            workflowId: workflowId,
            workflowVersion: 1,
            status: 'queued',
            createdAt: DateTime.now().toUtc().toIso8601String(),
            steps: const [],
          ),
        ];
      });
      if (dataSource != null) {
        await _refreshWorkTimeline();
      }
    } catch (error) {
      if (mounted) {
        final message =
            error is AxApiException && error.message.startsWith('Cannot run ')
                ? error.message
                : 'Could not run Work: $error';
        setState(() => _workSubmitError = message);
      }
    } finally {
      if (mounted) setState(() => _submittingWork = false);
    }
  }

  Future<void> _addWorkFiles() async {
    try {
      final selected = await work_request_files.pickWorkRequestFiles();
      final currentBytes = _workAttachments.fold<int>(
        0,
        (sum, item) => sum + (item['sizeBytes'] as int? ?? 0),
      );
      final selectedBytes = selected.fold<int>(
        0,
        (sum, item) => sum + (item['sizeBytes'] as int? ?? 0),
      );
      if (_workAttachments.length + selected.length > 10 ||
          currentBytes + selectedBytes > 1024 * 1024 ||
          selected
              .any((item) => (item['sizeBytes'] as int? ?? 0) > 1024 * 1024)) {
        throw const FormatException(
          'Choose up to 10 files, with each file and the total under 1 MB.',
        );
      }
      if (mounted && selected.isNotEmpty) {
        setState(() => _workAttachments = [..._workAttachments, ...selected]);
      }
    } on UnsupportedError catch (error) {
      if (mounted) setState(() => _workSubmitError = error.message.toString());
    } on FormatException catch (error) {
      if (mounted) setState(() => _workSubmitError = error.message.toString());
    }
  }

  Future<void> _addWorkReference() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a link'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://example.com'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add link'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty) return;
    if (_workAttachments.length >= 10) {
      if (mounted) {
        setState(() => _workSubmitError =
            'A Work Request can include up to 10 attachments.');
      }
      return;
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        value.length > 2048) {
      if (mounted) {
        setState(() => _workSubmitError =
            'Enter a valid http or https link (up to 2,048 characters).');
      }
      return;
    }
    if (mounted) {
      setState(() => _workAttachments = [
            ..._workAttachments,
            {
              'kind': 'url',
              'name': uri.host,
              'url': uri.toString(),
              'mediaType': 'text/uri-list',
              'sizeBytes': 0,
            },
          ]);
    }
  }

  Future<void> _refreshWorkTimeline({bool activeOnly = false}) async {
    final dataSource = widget.dataSource;
    if (dataSource == null) {
      if (_loadingWorkTimeline) {
        setState(() => _loadingWorkTimeline = false);
      }
      return;
    }
    if (_refreshingWorkTimeline) {
      _workTimelineRefreshPending = true;
      return;
    }
    _refreshingWorkTimeline = true;
    try {
      final requests = await dataSource.loadWorkstreamWorkRequests(
        workstreamId: widget.workstream.id,
        activeOnly: activeOnly,
      );
      if (!mounted) return;
      setState(() {
        if (activeOnly) {
          final updatedById = {
            for (final request in requests) request.id: request
          };
          _workTimeline = [
            for (final existing in _workTimeline)
              updatedById.remove(existing.id) ?? existing,
            ...updatedById.values,
          ]..sort((left, right) => left.createdAt.compareTo(right.createdAt));
        } else {
          _workTimeline = requests;
        }
        _loadingWorkTimeline = false;
        _workTimelineError = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loadingWorkTimeline = false;
          _workTimelineError = error.toString();
        });
      }
    } finally {
      _refreshingWorkTimeline = false;
      if (_workTimelineRefreshPending && mounted) {
        _workTimelineRefreshPending = false;
        unawaited(_refreshWorkTimeline(activeOnly: activeOnly));
      }
    }
  }

  Future<void> _showRunDetails(String workRequestId) async {
    final dataSource = widget.dataSource;
    if (dataSource == null) return;
    final details = dataSource.loadWorkRequest(workRequestId: workRequestId);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FutureBuilder<AxWorkRequestStatus>(
        future: details,
        builder: (context, snapshot) {
          final height = MediaQuery.sizeOf(context).height * 0.88;
          if (snapshot.hasError) {
            return SizedBox(
              height: height,
              child: const Center(child: Text('Could not load Run details.')),
            );
          }
          if (!snapshot.hasData) {
            return SizedBox(
              height: height,
              child: const Center(child: CircularProgressIndicator()),
            );
          }
          return _WorkRequestDetailsSheet(
            details: snapshot.data!,
            onRetryStep: (step) => _retryWorkRequestStep(
              workRequestId,
              step,
              closeDetails: true,
            ),
            onCancelRun: () => _cancelFailedWorkRequest(
              workRequestId,
              closeDetails: true,
            ),
          );
        },
      ),
    );
  }

  Future<void> _retryWorkRequestStep(
      String workRequestId, AxWorkRequestStep step,
      {bool closeDetails = false}) async {
    final dataSource = widget.dataSource;
    if (dataSource == null) return;
    String? sessionStrategy;
    if (step.kind == 'implement') {
      final resumeRecommended = const {
        'provider_unavailable',
        'authentication_required',
        'quota_exhausted',
        'worker_not_ready',
        'cli_not_found',
        'unsupported_cli_version',
        'model_not_supported',
        'permission_denied',
      }.contains(step.errorCode);
      final recommendation = resumeRecommended
          ? 'The failure looks like it happened before the Worker completed a turn. Resuming is recommended.'
          : 'The failure may have happened after work began. Starting fresh is recommended.';
      sessionStrategy = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Retry Implement'),
          content: Text(
            '$recommendation\n\nChoose how the retry should use provider context.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'resume'),
              child: Text(
                resumeRecommended
                    ? 'Resume previous session · Recommended'
                    : 'Resume previous session',
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, 'fresh'),
              child: Text(
                resumeRecommended ? 'Start fresh' : 'Start fresh · Recommended',
              ),
            ),
          ],
        ),
      );
      if (sessionStrategy == null) return;
    }
    try {
      await dataSource.retryWorkRequestStep(
        workRequestId: workRequestId,
        stepKind: step.kind,
        sessionStrategy: sessionStrategy,
      );
      if (!mounted) return;
      if (closeDetails) Navigator.of(context).pop();
      unawaited(_refreshWorkTimeline());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Retrying ${step.kind} Step.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not retry this Step. Check Worker readiness.'),
        ),
      );
    }
  }

  Future<void> _cancelFailedWorkRequest(
    String workRequestId, {
    bool closeDetails = false,
  }) async {
    final dataSource = widget.dataSource;
    if (dataSource == null) return;
    try {
      await dataSource.cancelWorkRequest(workRequestId: workRequestId);
      if (!mounted) return;
      if (closeDetails) Navigator.of(context).pop();
      unawaited(_refreshWorkTimeline());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Run cancelled.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not cancel this Run.')),
      );
    }
  }

  Future<void> _sendDiscussion() async {
    final text = _discussionController.text.trim();
    if (text.isEmpty) return;
    _discussionController.clear();
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final tempId = 'temp-${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _discussion.add(
        _DiscussionItem(
          id: tempId,
          author: 'You',
          text: text,
          sentAt: '$hour:$minute',
          isMe: true,
        ),
      );
    });

    final ds = widget.dataSource;
    if (ds != null) {
      try {
        final saved = await ds.sendDiscussionMessage(
          workstreamId: widget.workstream.id,
          text: text,
        );
        if (!mounted) return;
        setState(() {
          final idx = _discussion.indexWhere((item) => item.id == tempId);
          if (idx != -1) {
            final dt = DateTime.tryParse(saved.createdAt)?.toLocal();
            final timeStr = dt != null
                ? '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}'
                : '$hour:$minute';
            _discussion[idx] = _DiscussionItem(
              id: saved.id,
              author: 'You',
              text: saved.body,
              sentAt: timeStr,
              isMe: true,
            );
          }
        });
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save message: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _editDiscussion(String messageId, String newText) async {
    setState(() {
      final idx = _discussion.indexWhere((m) => m.id == messageId);
      if (idx != -1) {
        final old = _discussion[idx];
        _discussion[idx] = _DiscussionItem(
          id: old.id,
          author: old.author,
          text: newText,
          sentAt: old.sentAt,
          isMe: old.isMe,
        );
      }
    });

    final ds = widget.dataSource;
    if (ds != null && !messageId.startsWith('temp-')) {
      try {
        await ds.editDiscussionMessage(
          messageId: messageId,
          text: newText,
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update message: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }
}
