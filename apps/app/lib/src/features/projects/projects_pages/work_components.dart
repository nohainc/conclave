part of '../projects_pages.dart';

Widget _workflowOption(
  BuildContext context,
  AxBuiltinWorkflow workflow,
) =>
    ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: SizedBox(
        height: 54,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: workflow.name),
                const TextSpan(text: '  —  '),
                TextSpan(
                  text: workflow.description,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );

class AxModelOption {
  const AxModelOption({
    required this.id,
    required this.name,
    required this.badge,
    required this.description,
    this.minCliVersion,
  });

  final String id;
  final String name;
  final String badge;
  final String description;
  final String? minCliVersion;
}

List<AxModelOption> _modelsForWorker(AxWorker worker) {
  final workerType = worker.workerTypeId.toLowerCase();
  final profileId = (worker.profileDefinitionId ?? '').toLowerCase();
  final displayName = worker.displayName.toLowerCase();

  if (workerType == 'chatgpt' ||
      profileId.contains('chatgpt') ||
      profileId.contains('codex') ||
      displayName.contains('chatgpt') ||
      displayName.contains('openai')) {
    return const [
      AxModelOption(
        id: 'gpt-6.1-sol',
        name: 'GPT-6.1 Sol',
        badge: 'Workhorse',
        description: 'Latest workhorse model for coding and everyday work',
      ),
      AxModelOption(
        id: 'gpt-6-astra',
        name: 'GPT-6 Astra',
        badge: 'Frontier Reasoning',
        description: 'Frontier intelligence for the most demanding work',
      ),
      AxModelOption(
        id: 'gpt-6-sol',
        name: 'GPT-6 Sol',
        badge: 'Workhorse',
        description: 'Previous generation workhorse model',
      ),
      AxModelOption(
        id: 'gpt-6-luna',
        name: 'GPT-6 Luna',
        badge: 'Fast & Affordable',
        description: 'Fast and affordable model for easier tasks',
      ),
      AxModelOption(
        id: 'gpt-5.6-sol',
        name: 'GPT-5.6 Sol',
        badge: 'Workhorse',
        description: 'Older generation workhorse model',
      ),
      AxModelOption(
        id: 'gpt-5.6-terra',
        name: 'GPT-5.6 Terra',
        badge: 'Balanced',
        description: 'Older balanced model for straightforward work',
      ),
      AxModelOption(
        id: 'gpt-5.6-luna',
        name: 'GPT-5.6 Luna',
        badge: 'Fast',
        description: 'Older fast and efficient model',
      ),
      AxModelOption(
        id: 'gpt-reserve',
        name: 'GPT Reserve',
        badge: 'Agentic',
        description: 'Fast and affordable agentic coding model',
      ),
      AxModelOption(
        id: 'o3',
        name: 'o3',
        badge: 'Reasoning',
        description:
            'Most powerful reasoning model for coding, science, and math',
      ),
      AxModelOption(
        id: 'o3-mini',
        name: 'o3-mini',
        badge: 'Fast Reasoning',
        description:
            'High-speed reasoning specialized for STEM and programming',
      ),
      AxModelOption(
        id: 'o1',
        name: 'o1',
        badge: 'Reasoning',
        description:
            'Advanced full-scale reasoning model for deep logic problems',
      ),
      AxModelOption(
        id: 'o1-mini',
        name: 'o1-mini',
        badge: 'Fast Reasoning',
        description: 'Efficient reasoning model for fast coding tasks',
      ),
      AxModelOption(
        id: 'o1-preview',
        name: 'o1-preview',
        badge: 'Reasoning Preview',
        description: 'Preview reasoning model for multi-step reasoning',
      ),
      AxModelOption(
        id: 'gpt-4.5-preview',
        name: 'GPT-4.5',
        badge: 'Massive Knowledge',
        description:
            'Largest flagship model with broad world knowledge and deep nuance',
      ),
      AxModelOption(
        id: 'gpt-4o',
        name: 'GPT-4o',
        badge: 'Flagship',
        description:
            'High-intelligence flagship model for complex text, code, and reasoning',
      ),
      AxModelOption(
        id: 'gpt-4o-mini',
        name: 'GPT-4o mini',
        badge: 'Fast & Affordable',
        description: 'Lightweight and fast for everyday coding and tasks',
      ),
      AxModelOption(
        id: 'chatgpt-4o-latest',
        name: 'ChatGPT-4o',
        badge: 'Dynamic',
        description: 'Continuously updated ChatGPT-4o release',
      ),
      AxModelOption(
        id: 'codex-mini',
        name: 'Codex Mini',
        badge: 'Code Specialist',
        description: 'Fast low-latency code generation and refactoring',
      ),
      AxModelOption(
        id: 'gpt-4-turbo',
        name: 'GPT-4 Turbo',
        badge: 'Legacy',
        description: 'High-capacity GPT-4 model with 128k context',
      ),
      AxModelOption(
        id: 'gpt-4',
        name: 'GPT-4',
        badge: 'Legacy',
        description: 'Original GPT-4 instruction following model',
      ),
    ];
  } else if (workerType == 'copilot' ||
      profileId.contains('copilot') ||
      displayName.contains('copilot')) {
    return const [
      AxModelOption(
        id: 'claude-3.7-sonnet',
        name: 'Claude 3.7 Sonnet',
        badge: 'Hybrid Reasoning',
        description: 'Claude 3.7 with hybrid standard and extended thinking',
      ),
      AxModelOption(
        id: 'claude-3.5-sonnet',
        name: 'Claude 3.5 Sonnet',
        badge: 'Flagship Coding',
        description: 'Frontier code generation and multi-file editing',
      ),
      AxModelOption(
        id: 'gpt-4o',
        name: 'GPT-4o',
        badge: 'Flagship',
        description: 'High-speed intelligence for complex coding tasks',
      ),
      AxModelOption(
        id: 'o3-mini',
        name: 'o3-mini',
        badge: 'Fast Reasoning',
        description: 'High-speed reasoning specialized for STEM and coding',
      ),
      AxModelOption(
        id: 'o1',
        name: 'o1',
        badge: 'Reasoning',
        description: 'Advanced reasoning for deep architectural tasks',
      ),
    ];
  } else if (workerType == 'grok' ||
      profileId.contains('grok') ||
      profileId.contains('xai') ||
      displayName.contains('grok')) {
    return const [
      AxModelOption(
        id: 'grok-3',
        name: 'Grok 3',
        badge: 'Flagship Reasoning',
        description:
            'Frontier reasoning model with state-of-the-art coding and math',
      ),
      AxModelOption(
        id: 'grok-3-mini',
        name: 'Grok 3 mini',
        badge: 'Fast Reasoning',
        description: 'High-throughput lightweight reasoning model',
      ),
      AxModelOption(
        id: 'grok-2',
        name: 'Grok 2',
        badge: 'Flagship',
        description: 'State-of-the-art language and code generation',
      ),
      AxModelOption(
        id: 'grok-2-vision',
        name: 'Grok 2 Vision',
        badge: 'Multimodal',
        description: 'Visual reasoning and multimodal code synthesis',
      ),
      AxModelOption(
        id: 'grok-beta',
        name: 'Grok Beta',
        badge: 'Dynamic',
        description: 'Latest experimental release of Grok',
      ),
    ];
  } else if (workerType == 'claude' ||
      profileId.contains('claude') ||
      profileId.contains('anthropic') ||
      displayName.contains('claude')) {
    return const [
      AxModelOption(
        id: 'claude-3-7-sonnet',
        name: 'Claude 3.7 Sonnet',
        badge: 'Hybrid Reasoning',
        description:
            'Hybrid standard and extended thinking for high-level engineering',
      ),
      AxModelOption(
        id: 'claude-3-5-sonnet',
        name: 'Claude 3.5 Sonnet',
        badge: 'Flagship Coding',
        description:
            'Industry-standard model for code generation and refactoring',
      ),
      AxModelOption(
        id: 'claude-3-5-haiku',
        name: 'Claude 3.5 Haiku',
        badge: 'Ultra Fast',
        description: 'Near-instant responsiveness with high coding capability',
      ),
      AxModelOption(
        id: 'claude-3-opus',
        name: 'Claude 3 Opus',
        badge: 'Deep Reasoning',
        description: 'Top-level reasoning for complex open-ended analysis',
      ),
    ];
  } else if (workerType == 'gemini' ||
      profileId.contains('gemini') ||
      profileId.contains('antigravity') ||
      displayName.contains('gemini')) {
    return const [
      AxModelOption(
        id: 'gemini-2.5-pro',
        name: 'Gemini 2.5 Pro',
        badge: 'Flagship Thinking',
        description: 'Deep thinking, complex reasoning, and 1M+ token context',
      ),
      AxModelOption(
        id: 'gemini-2.5-flash',
        name: 'Gemini 2.5 Flash',
        badge: 'Fast & Smart',
        description:
            'Next-generation lightweight model with high speed and low latency',
      ),
      AxModelOption(
        id: 'gemini-2.0-flash',
        name: 'Gemini 2.0 Flash',
        badge: 'Multimodal',
        description: 'Fast multimodal performance for quick turnarounds',
      ),
      AxModelOption(
        id: 'gemini-1.5-pro',
        name: 'Gemini 1.5 Pro',
        badge: 'Long Context',
        description: '2M context window for massive codebase analysis',
      ),
      AxModelOption(
        id: 'gemini-1.5-flash',
        name: 'Gemini 1.5 Flash',
        badge: 'Fast',
        description: 'Lightweight and fast for general coding',
      ),
    ];
  } else if (workerType == 'deepseek' ||
      profileId.contains('deepseek') ||
      displayName.contains('deepseek')) {
    return const [
      AxModelOption(
        id: 'deepseek-reasoner',
        name: 'DeepSeek-R1',
        badge: 'Reasoning R1',
        description: 'Open reasoning model with chain-of-thought verification',
      ),
      AxModelOption(
        id: 'deepseek-chat',
        name: 'DeepSeek-V3',
        badge: 'Flagship V3',
        description: 'Fast 671B MoE model for general software engineering',
      ),
    ];
  } else if (workerType == 'ollama' ||
      profileId.contains('ollama') ||
      displayName.contains('ollama')) {
    return const [
      AxModelOption(
        id: 'llama3.3',
        name: 'Llama 3.3 70B',
        badge: 'Flagship Local',
        description: 'Meta Llama 3.3 70B versatile open model',
      ),
      AxModelOption(
        id: 'qwen2.5-coder',
        name: 'Qwen 2.5 Coder',
        badge: 'Code Specialist',
        description: 'Specialized code generation and fill-in-the-middle model',
      ),
      AxModelOption(
        id: 'deepseek-r1',
        name: 'DeepSeek-R1 Local',
        badge: 'Reasoning Local',
        description: 'Distilled local reasoning model for logic and code',
      ),
      AxModelOption(
        id: 'phi4',
        name: 'Phi-4',
        badge: 'Compact & Smart',
        description: 'Microsoft 14B state-of-the-art small language model',
      ),
      AxModelOption(
        id: 'mistral',
        name: 'Mistral 7B',
        badge: 'Fast Local',
        description: 'Fast lightweight open model for quick completions',
      ),
    ];
  }
  return const [];
}

String _modelDisplayName(String? modelId, {AxWorker? worker}) {
  if (modelId == null || modelId.trim().isEmpty) return '';
  final list =
      worker != null ? _modelsForWorker(worker) : const <AxModelOption>[];
  final found = list.where((m) => m.id == modelId).firstOrNull;
  if (found != null) return found.name;
  for (final typeId in [
    'chatgpt',
    'copilot',
    'grok',
    'claude',
    'gemini',
    'deepseek',
    'ollama',
  ]) {
    for (final option in _modelsForWorker(AxWorker(
      id: '',
      workspaceId: '',
      workspaceName: '',
      workerTypeId: typeId,
      displayName: '',
      status: '',
      readinessState: '',
      localConcurrencyLimit: 1,
      capabilities: const [],
    ))) {
      if (option.id == modelId) return option.name;
    }
  }
  return modelId;
}

Widget _buildModelBadge(BuildContext context, String badge) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  Color bg;
  Color fg;
  if (badge.contains('Reasoning') || badge.contains('Thinking')) {
    bg = isDark ? const Color(0xff2d234a) : const Color(0xffeedeff);
    fg = isDark ? const Color(0xffcfb2ff) : const Color(0xff6e3ab8);
  } else if (badge.contains('Flagship') || badge.contains('Knowledge')) {
    bg = isDark ? const Color(0xff182c44) : const Color(0xffdbeafe);
    fg = isDark ? const Color(0xff93c5fd) : const Color(0xff1e40af);
  } else if (badge.contains('Fast') || badge.contains('Smart')) {
    bg = isDark ? const Color(0xff143528) : const Color(0xffdcfce7);
    fg = isDark ? const Color(0xff86efac) : const Color(0xff166534);
  } else if (badge.contains('Code')) {
    bg = isDark ? const Color(0xff133238) : const Color(0xffccfbf1);
    fg = isDark ? const Color(0xff5eead4) : const Color(0xff115e59);
  } else if (badge.contains('Multimodal')) {
    bg = isDark ? const Color(0xff3d2e14) : const Color(0xfffef3c7);
    fg = isDark ? const Color(0xfffcd34d) : const Color(0xffb45309);
  } else {
    bg = isDark ? const Color(0xff2d2d2d) : const Color(0xfff3f4f6);
    fg = isDark ? const Color(0xff9ca3af) : const Color(0xff4b5563);
  }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      badge,
      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: fg),
    ),
  );
}

Future<T?> _showAnchoredMenu<T>({
  required BuildContext buttonContext,
  required GlobalKey inputKey,
  required List<PopupMenuEntry<T>> items,
  required double itemHeight,
  int dividerCount = 0,
}) async {
  final box = buttonContext.findRenderObject()! as RenderBox;
  final overlay =
      Overlay.of(buttonContext).context.findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  final inputBox = inputKey.currentContext?.findRenderObject() as RenderBox?;
  final anchorBottom = inputBox == null
      ? rect.top
      : inputBox.localToGlobal(Offset.zero, ancestor: overlay).dy +
          inputBox.size.height;
  final availableHeight = (anchorBottom - 8).clamp(0.0, overlay.size.height);
  final itemCount = items.length - dividerCount;
  final exactHeight = (itemCount * itemHeight) + (dividerCount * 16.0) + 16.0;
  final menuHeight = exactHeight.clamp(0.0, availableHeight);
  return showMenu<T>(
    context: buttonContext,
    popUpAnimationStyle: AnimationStyle.noAnimation,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    constraints: BoxConstraints(maxHeight: menuHeight),
    position: RelativeRect.fromRect(
      Rect.fromLTWH(rect.left, anchorBottom - menuHeight, rect.width, 0),
      Offset.zero & overlay.size,
    ),
    items: items,
  );
}

class _WorkComposer extends StatelessWidget {
  const _WorkComposer({
    required this.requestController,
    required this.historyController,
    required this.currentUserId,
    required this.currentUserName,
    required this.workflow,
    required this.workflowCatalog,
    this.workConfig = const <String, dynamic>{},
    this.projectWorkers = const <AxWorker>[],
    this.eligibleWorkers = const <AxWorker>[],
    required this.loadingWorkflows,
    required this.workflowCatalogError,
    required this.canExecute,
    this.canConfigureWork = true,
    required this.workTimeline,
    required this.localWorkProgress,
    required this.loadingTimeline,
    required this.timelineError,
    required this.submitError,
    required this.submitting,
    required this.awaitingResponse,
    required this.composerKey,
    required this.attachments,
    required this.onAddFiles,
    required this.onAddReference,
    required this.onRemoveAttachment,
    required this.onRefresh,
    required this.hasOlder,
    required this.loadingOlder,
    required this.onLoadOlder,
    required this.onShowRunDetails,
    required this.onRetryStep,
    required this.onCancelRun,
    required this.onWorkflowChanged,
    this.onModelChanged,
    this.onOpenSettings,
    required this.onRun,
  });

  final TextEditingController requestController;
  final ScrollController historyController;
  final String? currentUserId;
  final String? currentUserName;
  final String workflow;
  final List<AxBuiltinWorkflow> workflowCatalog;
  final Map<String, dynamic> workConfig;
  final List<AxWorker> projectWorkers;
  final List<AxWorker> eligibleWorkers;
  final bool loadingWorkflows;
  final String? workflowCatalogError;
  final bool canExecute;
  final bool canConfigureWork;
  final List<AxWorkRequest> workTimeline;
  final Map<String, String> localWorkProgress;
  final bool loadingTimeline;
  final String? timelineError;
  final String? submitError;
  final bool submitting;
  final bool awaitingResponse;
  final GlobalKey composerKey;
  final List<Map<String, dynamic>> attachments;
  final Future<void> Function() onAddFiles;
  final Future<void> Function() onAddReference;
  final ValueChanged<int> onRemoveAttachment;
  final Future<void> Function() onRefresh;
  final bool hasOlder;
  final bool loadingOlder;
  final Future<void> Function() onLoadOlder;
  final ValueChanged<String>? onShowRunDetails;
  final Future<void> Function(String, AxWorkRequestStep)? onRetryStep;
  final Future<void> Function(String)? onCancelRun;
  final ValueChanged<String> onWorkflowChanged;
  final void Function(String stepKind, String model)? onModelChanged;
  final VoidCallback? onOpenSettings;
  final Future<void> Function() onRun;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: history(context)),
        const SizedBox(height: 16),
        controls(context)
      ]);

  Widget history(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
        controller: historyController,
        key: const ValueKey('work-history-scroll'),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (hasOlder)
            TextButton(
                onPressed: loadingOlder ? null : onLoadOlder,
                child: Text(loadingOlder
                    ? 'Loading older Work history…'
                    : 'Load older Work history')),
          if (timelineError != null && workTimeline.isNotEmpty)
            TextButton(
                onPressed: onRefresh, child: const Text('Retry Work sync')),
          if (loadingTimeline && workTimeline.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: LinearProgressIndicator(),
            )
          else if (timelineError != null && workTimeline.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'Could not load Work history: $timelineError',
                style: TextStyle(color: colors.error),
              ),
            )
          else if (workTimeline.isEmpty)
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
                    'No work requests yet',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Ask AI to do something for the team. Nothing runs until you send the request.',
                    textAlign: TextAlign.center,
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
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: workTimeline.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final request = workTimeline[index];
                return _WorkTimelineCard(
                  key: ValueKey(request.id),
                  request: request,
                  progressText: localWorkProgress[request.id],
                  currentUserId: currentUserId,
                  currentUserName: currentUserName,
                  workflowCatalog: workflowCatalog,
                  onShowRunDetails: localWorkProgress.containsKey(request.id)
                      ? null
                      : onShowRunDetails,
                  onRetryStep: localWorkProgress.containsKey(request.id)
                      ? null
                      : onRetryStep,
                  onCancelRun: localWorkProgress.containsKey(request.id)
                      ? null
                      : onCancelRun,
                );
              },
            ),
        ]));
  }

  AxWorker? get _assignedWorker {
    final selectedWorkflow = workflowCatalog
            .where((item) => item.reference == workflow)
            .firstOrNull ??
        workflowCatalog
            .where((item) => item.id == workflow.split(':').first)
            .firstOrNull;
    final bindings = workConfig['bindings'] is Map
        ? Map<String, dynamic>.from(workConfig['bindings'] as Map)
        : <String, dynamic>{};
    final stepKind = selectedWorkflow?.steps.firstOrNull?.kind ??
        (selectedWorkflow?.id == 'chat' ? 'chat' : 'implement');
    final rawBinding = bindings[stepKind] ??
        (selectedWorkflow != null ? bindings[selectedWorkflow.id] : null);
    final binding = rawBinding is Map
        ? Map<String, dynamic>.from(rawBinding)
        : <String, dynamic>{};
    final workerId =
        (binding['workerId'] ?? binding['worker_id'])?.toString() ?? '';
    if (workerId.isEmpty) return null;
    return eligibleWorkers.where((w) => w.id == workerId).firstOrNull ??
        projectWorkers.where((w) => w.id == workerId).firstOrNull;
  }

  bool get _isWorkerAssigned {
    final worker = _assignedWorker;
    return worker != null && eligibleWorkers.any((w) => w.id == worker.id);
  }

  Widget controls(BuildContext context) => _buildComposerInput(
      context,
      Theme.of(context).brightness == Brightness.dark,
      Theme.of(context).colorScheme);

  Widget _additionalControls(BuildContext context, GlobalKey inputKey) {
    final colors = Theme.of(context).colorScheme;
    final selectedWorkflow = workflowCatalog
            .where((item) => item.reference == workflow)
            .firstOrNull ??
        workflowCatalog
            .where((item) => item.id == workflow.split(':').first)
            .firstOrNull;

    final bindings = workConfig['bindings'] is Map
        ? Map<String, dynamic>.from(workConfig['bindings'] as Map)
        : <String, dynamic>{};
    final stepKind = selectedWorkflow?.steps.firstOrNull?.kind ??
        (selectedWorkflow?.id == 'chat' ? 'chat' : 'implement');
    final rawBinding = bindings[stepKind] ??
        (selectedWorkflow != null ? bindings[selectedWorkflow.id] : null);
    final binding = rawBinding is Map
        ? Map<String, dynamic>.from(rawBinding)
        : <String, dynamic>{};
    final assignedWorker = _assignedWorker;
    final isWorkerAssigned = _isWorkerAssigned;
    final selectedModel = binding['model']?.toString().trim() ?? '';
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final availableModels =
        assignedWorker != null ? _modelsForWorker(assignedWorker) : const <AxModelOption>[];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Builder(
            builder: (buttonContext) => IconButton(
              tooltip: 'Add attachments',
              icon: const Icon(Icons.add, size: 18),
              onPressed: () async {
                final value = await _showAnchoredMenu<String>(
                  buttonContext: buttonContext,
                  inputKey: inputKey,
                  itemHeight: 48.0,
                  items: [
                    PopupMenuItem(
                      value: 'files',
                      enabled: canExecute && !submitting,
                      child: const ListTile(
                        dense: true,
                        leading: Icon(Icons.attach_file, size: 18),
                        title: Text('Add files'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'link',
                      enabled: canExecute && !submitting,
                      child: const ListTile(
                        dense: true,
                        leading: Icon(Icons.link, size: 18),
                        title: Text('Add link'),
                      ),
                    ),
                  ],
                );
                if (!buttonContext.mounted || value == null) return;
                if (value == 'files') {
                  onAddFiles();
                } else if (value == 'link') {
                  onAddReference();
                }
              },
            ),
          ),
          IconButton(
            tooltip: 'Refresh Work history',
            onPressed: () => onRefresh(),
            icon: const Icon(Icons.refresh, size: 18),
          ),
          if (onOpenSettings != null)
            IconButton(
              tooltip: 'Work settings',
              onPressed: onOpenSettings,
              icon: const Icon(Icons.tune_rounded, size: 18),
            ),
          const SizedBox(width: 4),
          Builder(
            builder: (workflowBtnContext) => Tooltip(
              message: 'Choose workflow',
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: canExecute && !submitting && workflowCatalog.isNotEmpty
                    ? () async {
                        final versions =
                            _currentWorkflowVersions(workflowCatalog);
                        final value = await _showAnchoredMenu<String>(
                          buttonContext: workflowBtnContext,
                          inputKey: inputKey,
                          itemHeight: 48.0,
                          items: [
                            for (final item in versions)
                              CheckedPopupMenuItem(
                                value: item.reference,
                                checked: item.reference == workflow,
                                enabled: canExecute && !submitting,
                                child: Tooltip(
                                  message: item.description,
                                  child: Text(item.name),
                                ),
                              ),
                          ],
                        );
                        if (!workflowBtnContext.mounted || value == null) return;
                        onWorkflowChanged(value);
                      }
                    : null,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 130),
                        child: Text(
                          selectedWorkflow?.name ?? 'Choose workflow',
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      const Icon(Icons.keyboard_arrow_down, size: 14),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (!isWorkerAssigned)
            Tooltip(
              message: onOpenSettings != null
                  ? 'No worker assigned for this workflow. Click to configure in Work settings.'
                  : 'No worker assigned for this workflow.',
              child: InkWell(
                onTap: onOpenSettings,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline_rounded,
                          size: 14, color: colors.error),
                      const SizedBox(width: 4),
                      Text(
                        'No worker assigned',
                        style: TextStyle(
                          color: colors.error,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            Builder(
              builder: (modelBtnContext) => Tooltip(
                message: 'Choose model',
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: canExecute && !submitting && onModelChanged != null
                      ? () async {
                          final menuItems = <PopupMenuEntry<String>>[
                            CheckedPopupMenuItem<String>(
                              value: '',
                              checked: selectedModel.isEmpty,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child: SizedBox(
                                height: 46,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Text(
                                      'Default model',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Uses the worker’s configured model',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: isDark
                                            ? Colors.white60
                                            : Colors.black54,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (availableModels.isNotEmpty)
                              const PopupMenuDivider(),
                            for (final model in availableModels)
                              CheckedPopupMenuItem<String>(
                                value: model.id,
                                checked: selectedModel == model.id,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                child: SizedBox(
                                  height: 46,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            model.name,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          _buildModelBadge(
                                              context, model.badge),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        model.description,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: isDark
                                              ? Colors.white60
                                              : Colors.black54,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ];
                          final value = await _showAnchoredMenu<String>(
                            buttonContext: modelBtnContext,
                            inputKey: inputKey,
                            items: menuItems,
                            itemHeight: 52.0,
                            dividerCount:
                                availableModels.isNotEmpty ? 1 : 0,
                          );
                          if (!modelBtnContext.mounted || value == null) return;
                          onModelChanged?.call(stepKind, value);
                        }
                      : null,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 130),
                          child: Text(
                            _modelDisplayName(selectedModel,
                                    worker: assignedWorker)
                                .isEmpty
                                ? 'Default model'
                                : _modelDisplayName(selectedModel,
                                    worker: assignedWorker),
                            overflow: TextOverflow.ellipsis,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Icon(Icons.keyboard_arrow_down, size: 14),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildComposerInput(
    BuildContext context,
    bool isDark,
    ColorScheme colors,
  ) {
    return Container(
      padding: EdgeInsets.zero,
      key: composerKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MarkdownComposer(
            controller: requestController,
            chatStyle: true,
            minLines: 2,
            maxLines: 6,
            enabled: canExecute && !submitting,
            onSend: () => onRun(),
            sendTooltip: 'Run Work',
            sendEnabled: canExecute &&
                !awaitingResponse &&
                !loadingWorkflows &&
                workflowCatalogError == null,
            additionalControlsBuilder: (inputKey) =>
                _additionalControls(context, inputKey),
          ),
          if (attachments.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (var i = 0; i < attachments.length; i++)
                  InputChip(
                    avatar: Icon(
                      attachments[i]['kind'] == 'url'
                          ? Icons.link
                          : Icons.insert_drive_file,
                      size: 14,
                    ),
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(
                        (attachments[i]['name'] ?? 'Attachment').toString(),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    onDeleted: canExecute && !submitting
                        ? () => onRemoveAttachment(i)
                        : null,
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Up to 10 attachments. Files total 1 MB; links are passed as references.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
          if (loadingWorkflows) const LinearProgressIndicator(),
          if (workflowCatalogError != null)
            Text(workflowCatalogError!, style: TextStyle(color: colors.error)),
          if (!canExecute)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Viewer access can read the workstream but cannot run Work.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          if (submitError != null) ...[
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: SelectableText(
                  submitError!,
                  style: ConclaveMessageTypography.fromTheme(Theme.of(context))
                      .copyWith(color: colors.error),
                ),
              ),
              IconButton(
                tooltip: 'Copy Run error',
                icon: const Icon(Icons.copy_outlined, size: 16),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: submitError!));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Run error copied')),
                    );
                  }
                },
              ),
            ]),
          ],
        ],
      ),
    );
  }
}

class _WorkTimelineCard extends StatelessWidget {
  const _WorkTimelineCard({
    super.key,
    required this.request,
    this.progressText,
    required this.currentUserId,
    required this.currentUserName,
    required this.workflowCatalog,
    required this.onShowRunDetails,
    required this.onRetryStep,
    required this.onCancelRun,
  });

  final AxWorkRequest request;
  final String? progressText;
  final String? currentUserId;
  final String? currentUserName;
  final List<AxBuiltinWorkflow> workflowCatalog;
  final ValueChanged<String>? onShowRunDetails;
  final Future<void> Function(String, AxWorkRequestStep)? onRetryStep;
  final Future<void> Function(String)? onCancelRun;

  String get _workflowName =>
      request.workflowName ??
      workflowCatalog
          .where((workflow) =>
              workflow.id == request.workflowId &&
              workflow.version == request.workflowVersion)
          .map((workflow) => workflow.name)
          .firstOrNull ??
      request.workflowId;

  String _elapsed(int? milliseconds) {
    if (milliseconds == null) return '';
    final seconds = milliseconds ~/ 1000;
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return minutes > 0 ? '${minutes}m ${remainder}s' : '${remainder}s';
  }

  String _totalElapsed() {
    final elapsed = request.steps
        .map((step) => step.elapsedMs)
        .whereType<int>()
        .fold<int>(0, (total, value) => total + value);
    return elapsed == 0 ? '' : _elapsed(elapsed);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;
    final metaColor = isDark ? Colors.white38 : Colors.black45;

    final timestamp = DateTime.tryParse(request.createdAt)?.toLocal();
    final timeLabel = timestamp == null ? '' : _chatTimestamp(timestamp);
    final elapsed = _totalElapsed();
    final requesterInitials = request.requestedByName.isNotEmpty
        ? request.requestedByName
            .trim()
            .split(' ')
            .where((s) => s.isNotEmpty)
            .map((s) => s[0])
            .take(2)
            .join()
            .toUpperCase()
        : 'U';
    final normalizedRequesterName =
        request.requestedByName.trim().toLowerCase();
    final normalizedCurrentName = currentUserName?.trim().toLowerCase();
    final isOwnRequest = (currentUserId != null &&
            currentUserId!.isNotEmpty &&
            request.requestedByUserId == currentUserId) ||
        (normalizedCurrentName != null &&
            normalizedCurrentName.isNotEmpty &&
            normalizedRequesterName == normalizedCurrentName);
    final showRequesterIdentity =
        !isOwnRequest && request.requestedByUserId?.trim().isNotEmpty == true;

    final failedStep =
        request.steps.where((step) => step.status == 'failed').firstOrNull;
    final lastCompletedStep = request.steps
        .where((step) =>
            step.status == 'completed' &&
            step.resultText?.trim().isNotEmpty == true)
        .lastOrNull;
    final activeStep = request.steps
        .where((step) => step.status == 'running' || step.status == 'waiting')
        .firstOrNull;
    final stepForContext =
        lastCompletedStep ?? activeStep ?? request.steps.firstOrNull;
    final selectedModel = stepForContext?.model?.trim();

    final response = request.finalText?.trim().isNotEmpty == true
        ? request.finalText!
        : request.steps
            .map((step) => step.resultText)
            .whereType<String>()
            .where((text) => text.trim().isNotEmpty)
            .firstOrNull;
    final error = request.error?.trim().isNotEmpty == true
        ? request.error!
        : failedStep?.errorMessage;
    final isError = error?.isNotEmpty == true;

    final workerDisplayName = lastCompletedStep?.workerDisplayName?.trim() ??
        stepForContext?.workerDisplayName?.trim();
    final isWorkerResponse = !isError &&
        response?.isNotEmpty == true &&
        workerDisplayName?.isNotEmpty == true;
    final senderName = isWorkerResponse ? workerDisplayName! : 'Conclave';

    final metadataSegments = [
      if (_workflowName.isNotEmpty) _workflowName,
      if (selectedModel != null && selectedModel.isNotEmpty) selectedModel,
      if (elapsed.isNotEmpty) elapsed,
    ];
    final metadataString =
        metadataSegments.isEmpty ? '' : '· ${metadataSegments.join(' · ')}';

    final Widget senderAvatar = isWorkerResponse
        ? CircleAvatar(
            radius: 11,
            backgroundColor:
                isDark ? const Color(0xff2a2940) : const Color(0xffece9f8),
            child: const Icon(
              Icons.smart_toy_outlined,
              size: 13,
              color: Color(0xff7c3aed),
            ),
          )
        : Image.asset(
            'assets/branding/conclave_logo_32.png',
            width: 20,
            height: 20,
            fit: BoxFit.contain,
            errorBuilder: (ctx, err, stack) => const Icon(
              Icons.auto_awesome,
              size: 14,
              color: Color(0xff7c3aed),
            ),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // User prompt bubble
        Align(
          alignment:
              isOwnRequest ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Container(
              decoration: BoxDecoration(
                color: isOwnRequest
                    ? (isDark
                        ? ConclaveBrand.navigationSelection
                        : ConclaveBrand.accentWash)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              padding: EdgeInsets.fromLTRB(isOwnRequest ? 14 : 0, 10, 14, 10),
              child: Column(
                crossAxisAlignment: isOwnRequest
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showRequesterIdentity) ...[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 11,
                          backgroundColor: isDark
                              ? const Color(0xff3f3b61)
                              : const Color(0xffd8d2ff),
                          child: Text(
                            requesterInitials,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: isDark
                                  ? Colors.white70
                                  : const Color(0xff4238a0),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          request.requestedByName,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                  ],
                  ConclaveMarkdownBody(data: request.prompt),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (timeLabel.isNotEmpty) ...[
                        Text(
                          timeLabel,
                          style: TextStyle(fontSize: 11, color: metaColor),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Tooltip(
                        message: 'Copy Markdown',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: () {
                            Clipboard.setData(
                                ClipboardData(text: request.prompt));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Prompt copied to clipboard'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Icon(
                              Icons.copy_rounded,
                              size: 14,
                              color: metaColor,
                            ),
                          ),
                        ),
                      ),
                    ].orderedForMessage(isOwnRequest),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // AI Execution & response bubble
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.fromLTRB(0, 14, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      senderAvatar,
                      const SizedBox(width: 6),
                      Text(
                        senderName,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      if (metadataString.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            metadataString,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: metaColor),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 10),
                  Builder(builder: (context) {
                    final failedStep = request.steps
                        .where((step) => step.status == 'failed')
                        .firstOrNull;
                    final response =
                        request.finalText?.trim().isNotEmpty == true
                            ? request.finalText!
                            : request.steps
                                .map((step) => step.resultText)
                                .whereType<String>()
                                .where((text) => text.trim().isNotEmpty)
                                .firstOrNull;
                    final error = request.error?.trim().isNotEmpty == true
                        ? request.error!
                        : failedStep?.errorMessage;
                    final message = error?.isNotEmpty == true
                        ? error!
                        : response?.isNotEmpty == true
                            ? response!
                            : request.status == 'cancelled'
                                ? 'Run cancelled.'
                                : progressText ??
                                    switch (request.status) {
                                      'running' => 'Working on your request…',
                                      'waiting' => 'Waiting for the next step…',
                                      'completed' => 'Request completed.',
                                      'failed' =>
                                        'Your request could not be completed.',
                                      _ => 'Preparing your request…',
                                    };
                    final isError = error?.isNotEmpty == true;
                    Widget compactAction({
                      required String tooltip,
                      required IconData icon,
                      required VoidCallback onPressed,
                    }) =>
                        Tooltip(
                          message: tooltip,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: onPressed,
                            child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: Icon(
                                icon,
                                size: 15,
                                color: metaColor,
                              ),
                            ),
                          ),
                        );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (isError)
                          SelectableText(
                            message,
                            style: ConclaveMessageTypography.fromTheme(
                                    Theme.of(context))
                                .copyWith(color: colors.error),
                          )
                        else
                          ConclaveMarkdownBody(data: message),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (response?.isNotEmpty == true ||
                                error?.isNotEmpty == true)
                              compactAction(
                                tooltip:
                                    isError ? 'Copy error' : 'Copy Markdown',
                                icon: Icons.copy_outlined,
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(
                                    text: isError ? error! : response!,
                                  ));
                                },
                              ),
                            if (onShowRunDetails != null)
                              compactAction(
                                tooltip: 'View run details',
                                icon: Icons.info_outline,
                                onPressed: () => onShowRunDetails!(request.id),
                              ),
                            if (request.status == 'failed' &&
                                failedStep != null &&
                                onRetryStep != null)
                              compactAction(
                                tooltip: 'Retry failed Step',
                                icon: Icons.refresh,
                                onPressed: () =>
                                    onRetryStep!(request.id, failedStep),
                              ),
                            if ((request.status == 'queued' ||
                                    request.status == 'running') &&
                                onCancelRun != null)
                              compactAction(
                                tooltip: 'Cancel run',
                                icon: Icons.cancel_outlined,
                                onPressed: () => onCancelRun!(request.id),
                              ),
                            const SizedBox(width: 8),
                            if (timeLabel.isNotEmpty)
                              Text(
                                timeLabel,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: metaColor,
                                ),
                              ),
                          ],
                        ),
                      ],
                    );
                  }),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _WorkRequestDetailsSheet extends StatelessWidget {
  const _WorkRequestDetailsSheet({
    required this.details,
    required this.onRetryStep,
    required this.onCancelRun,
  });

  final AxWorkRequestStatus details;
  final Future<void> Function(AxWorkRequestStep step) onRetryStep;
  final Future<void> Function() onCancelRun;

  String _stepName(String kind) => switch (kind) {
        'research' => 'Research',
        'plan' => 'Plan',
        'implement' => 'Implement',
        'test' => 'Test',
        'verify' => 'Verify',
        _ => kind,
      };

  String _workerName(AxWorkRequestStep step) =>
      step.workerDisplayName ?? 'Worker';

  String _timestamp(String? value) {
    if (value == null) return '—';
    final parsed = DateTime.tryParse(value)?.toLocal();
    if (parsed == null) return '—';
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')} '
        '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}:${parsed.second.toString().padLeft(2, '0')}';
  }

  String _duration(int? milliseconds) {
    if (milliseconds == null) return '—';
    final seconds = milliseconds ~/ 1000;
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return minutes > 0 ? '${minutes}m ${remainder}s' : '${remainder}s';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final workflow = details.workflowName ?? details.workflowId ?? 'Workflow';
    final version = details.workflowVersion;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.88,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text('Run details',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                Text(
                  '$workflow${version == null ? '' : ' · v$version'} · ${details.status}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (details.requestedByName?.isNotEmpty == true) ...[
                  const SizedBox(height: 6),
                  Text('Requested by ${details.requestedByName}'),
                ],
                const SizedBox(height: 16),
                Text('Original request',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                ConclaveMarkdownBody(
                    data: details.originalRequest?.isNotEmpty == true
                        ? details.originalRequest!
                        : 'No request text was recorded.'),
                const SizedBox(height: 20),
                for (final step in details.steps) ...[
                  Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(_stepName(step.kind),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                              ),
                              Text(step.status),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            [
                              _workerName(step),
                              if (step.engineVersion != null)
                                'Engine ${step.engineVersion}',
                              if (step.providerToolName != null &&
                                  step.providerToolVersion != null)
                                '${step.providerToolName} ${step.providerToolVersion}',
                              if (step.providerToolName != null &&
                                  step.providerToolVersion == null)
                                step.providerToolName!,
                            ].join(' · '),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 18,
                            runSpacing: 6,
                            children: [
                              Text('Started · ${_timestamp(step.startedAt)}'),
                              Text('Ended · ${_timestamp(step.completedAt)}'),
                              Text('Duration · ${_duration(step.elapsedMs)}'),
                            ],
                          ),
                          if (step.resultText?.isNotEmpty == true) ...[
                            const Divider(height: 24),
                            Text('Result',
                                style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 6),
                            ConclaveMarkdownBody(data: step.resultText!),
                          ] else if (step.status == 'failed') ...[
                            const Divider(height: 24),
                            SelectableText(
                              step.errorMessage ??
                                  'This Step did not produce a result.',
                              style: ConclaveMessageTypography.fromTheme(
                                      Theme.of(context))
                                  .copyWith(color: colors.error),
                            ),
                            if (details.status == 'failed') ...[
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                onPressed: () => onRetryStep(step),
                                icon: const Icon(Icons.refresh),
                                label: const Text('Retry step'),
                              ),
                            ],
                          ],
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            childrenPadding: EdgeInsets.zero,
                            title: const Text('Advanced technical details'),
                            children: [
                              if (step.assignmentId != null)
                                _detailValue(
                                    'Assignment ID', step.assignmentId!),
                              if (step.engineVersion != null)
                                _detailValue(
                                    'Engine version', step.engineVersion!),
                              if (step.profileDefinitionId != null)
                                _detailValue(
                                  'Tool Profile',
                                  '${step.profileDefinitionId}'
                                      '${step.profileReleaseVersion == null ? '' : '@${step.profileReleaseVersion}'}',
                                ),
                              if (step.providerToolVersion != null)
                                _detailValue(
                                    '${step.providerToolName ?? 'Provider tool'} version',
                                    step.providerToolVersion!),
                              if (step.model != null)
                                _detailValue('Model', step.model!),
                              if (step.sessionPolicy != null)
                                _detailValue(
                                  'Session mode',
                                  step.sessionPolicy == 'durable_session'
                                      ? 'Durable session'
                                      : 'Stateless',
                                ),
                              if (step.retrySessionStrategy != null)
                                _detailValue(
                                  'Last retry session',
                                  step.retrySessionStrategy == 'fresh'
                                      ? 'Started fresh'
                                      : 'Resumed previous session',
                                ),
                              if (step.errorCode != null)
                                _detailValue(
                                    'Stable error code', step.errorCode!),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (details.errorCode != null &&
                    details.steps.every((step) => step.errorCode == null))
                  SelectableText('Run error code: ${details.errorCode}'),
                if (details.status == 'failed' ||
                    details.status == 'queued' ||
                    details.status == 'running') ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: onCancelRun,
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Cancel run'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailValue(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 180, child: Text(label)),
            Expanded(child: SelectableText(value)),
          ],
        ),
      );
}

class _DiscussionItem {
  const _DiscussionItem({
    required this.id,
    required this.author,
    required this.text,
    this.sentAt,
    this.isMe = true,
  });

  final String id;
  final String author;
  final String text;
  final String? sentAt;
  final bool isMe;
}

class _DiscussionMessageBubble extends StatefulWidget {
  const _DiscussionMessageBubble({
    super.key,
    required this.item,
    required this.onCopy,
    required this.onEdit,
  });

  final _DiscussionItem item;
  final VoidCallback onCopy;
  final ValueChanged<String> onEdit;

  @override
  State<_DiscussionMessageBubble> createState() =>
      _DiscussionMessageBubbleState();
}

class _DiscussionMessageBubbleState extends State<_DiscussionMessageBubble> {
  bool _isEditing = false;
  late TextEditingController _editController;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController(text: widget.item.text);
  }

  @override
  void didUpdateWidget(covariant _DiscussionMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.text != widget.item.text && !_isEditing) {
      _editController.text = widget.item.text;
    }
  }

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  void _saveEdit() {
    final text = _editController.text;
    if (text.trim().isNotEmpty) {
      widget.onEdit(text);
    }
    setState(() => _isEditing = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMe = widget.item.isMe;

    final initials = widget.item.author.isNotEmpty
        ? widget.item.author
            .trim()
            .split(' ')
            .where((s) => s.isNotEmpty)
            .map((s) => s[0])
            .take(2)
            .join()
            .toUpperCase()
        : 'U';

    final metaColor = isDark ? Colors.white38 : Colors.black45;
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Container(
          decoration: BoxDecoration(
            color: isMe
                ? (isDark
                    ? ConclaveBrand.navigationSelection
                    : ConclaveBrand.accentWash)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          padding: EdgeInsets.fromLTRB(isMe ? 14 : 0, 10, 14, 10),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isMe) ...[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 11,
                      backgroundColor: isDark
                          ? const Color(0xff3f3b61)
                          : const Color(0xffd8d2ff),
                      child: Text(
                        initials,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color:
                              isDark ? Colors.white70 : const Color(0xff4238a0),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      widget.item.author,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
              if (_isEditing) ...[
                MarkdownComposer(
                  controller: _editController,
                  compact: true,
                  maxLines: 6,
                  autofocus: true,
                  chatStyle: true,
                  onSubmit: _saveEdit,
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => setState(() {
                        _editController.text = widget.item.text;
                        _isEditing = false;
                      }),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _saveEdit,
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ] else ...[
                ConclaveMarkdownBody(data: widget.item.text),
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.item.sentAt != null) ...[
                      Text(
                        widget.item.sentAt!,
                        style: TextStyle(
                          fontSize: 11,
                          color: metaColor,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (!widget.item.id.startsWith('temp-'))
                      Tooltip(
                        message: 'Edit message',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: () => setState(() {
                            _editController.text = widget.item.text;
                            _isEditing = true;
                          }),
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Icon(
                              Icons.edit_outlined,
                              size: 14,
                              color: metaColor,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'Copy Markdown',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: widget.onCopy,
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            Icons.copy_rounded,
                            size: 14,
                            color: metaColor,
                          ),
                        ),
                      ),
                    ),
                  ].orderedForMessage(isMe),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// Own-message metadata follows reading order toward the right edge.
extension _MessageFooterOrder on List<Widget> {
  List<Widget> orderedForMessage(bool own) => own ? this : reversed.toList();
}
