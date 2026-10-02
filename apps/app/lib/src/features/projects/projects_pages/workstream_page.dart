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

  void _updateState(VoidCallback callback) => setState(callback);

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
}
