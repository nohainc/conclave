enum RunStatus {
  active,
  running,
  waiting,
  paused,
  completed,
  failed,
  cancelled
}

enum TaskStatus { completed, running, ready, blocked, pending }

enum FindingSeverity { blocker, major, minor, note }

enum FindingStatus { open, fixed, verified }

enum StudioQualityPreset {
  economy,
  balanced,
  highAssurance,
  exploration,
  custom
}

class StudioPolicy {
  const StudioPolicy({
    required this.preset,
    required this.mode,
    required this.candidateCount,
    required this.maxParallel,
    required this.costCeiling,
    required this.requiresSynthesis,
  });

  final StudioQualityPreset preset;
  final String mode;
  final int candidateCount;
  final int maxParallel;
  final String costCeiling;
  final bool requiresSynthesis;

  factory StudioPolicy.fromJson(Map<String, dynamic> json) => StudioPolicy(
        preset: switch (_string(json, 'preset')) {
          'economy' => StudioQualityPreset.economy,
          'high_assurance' => StudioQualityPreset.highAssurance,
          'exploration' => StudioQualityPreset.exploration,
          'custom' => StudioQualityPreset.custom,
          _ => StudioQualityPreset.balanced,
        },
        mode: _string(json, 'mode', 'parallel'),
        candidateCount: json['candidateCount'] as int? ?? 2,
        maxParallel: json['maxParallel'] as int? ?? 2,
        costCeiling: _string(json, 'costCeiling', 'No ceiling'),
        requiresSynthesis: json['requiresSynthesis'] as bool? ?? false,
      );
}

class StudioCandidateOutput {
  const StudioCandidateOutput({
    required this.worker,
    required this.role,
    required this.status,
    required this.summary,
    required this.artifactCount,
  });

  final String worker;
  final String role;
  final String status;
  final String summary;
  final int artifactCount;

  factory StudioCandidateOutput.fromJson(Map<String, dynamic> json) =>
      StudioCandidateOutput(
        worker: _string(json, 'worker'),
        role: _string(json, 'role'),
        status: _string(json, 'status'),
        summary: _string(json, 'summary'),
        artifactCount: json['artifactCount'] as int? ?? 0,
      );
}

class StudioSynthesisDecision {
  const StudioSynthesisDecision({
    required this.status,
    required this.summary,
    required this.worker,
    required this.evidence,
  });

  final String status;
  final String summary;
  final String worker;
  final String evidence;

  factory StudioSynthesisDecision.fromJson(Map<String, dynamic> json) =>
      StudioSynthesisDecision(
        status: _string(json, 'status'),
        summary: _string(json, 'summary'),
        worker: _string(json, 'worker'),
        evidence: _string(json, 'evidence'),
      );
}

String _string(Map<String, dynamic> json, String key, [String fallback = '—']) {
  final value = json[key];
  return value == null ? fallback : value.toString();
}

List<String> _strings(Map<String, dynamic> json, String key) =>
    List<String>.from(json[key] as List? ?? const []);

Map<String, dynamic> _map(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
}

enum StudioMessageSender { user, conclave, system }

enum StudioMessageRole { user, assistant, system }

extension StudioMessageSenderRole on StudioMessageSender {
  StudioMessageRole get role => switch (this) {
        StudioMessageSender.user => StudioMessageRole.user,
        StudioMessageSender.conclave => StudioMessageRole.assistant,
        StudioMessageSender.system => StudioMessageRole.system,
      };
}

enum StudioPhaseStatus { completed, inProgress, pending }

class StudioPhaseItem {
  const StudioPhaseItem({
    required this.name,
    required this.status,
    this.detail,
  });

  final String name;
  final StudioPhaseStatus status;
  final String? detail;

  factory StudioPhaseItem.fromJson(Map<String, dynamic> json) =>
      StudioPhaseItem(
        name: _string(json, 'name'),
        status: StudioPhaseStatus.values.firstWhere(
          (v) => v.name == json['status'],
          orElse: () => StudioPhaseStatus.pending,
        ),
        detail: json['detail'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'status': status.name,
        'detail': detail,
      };
}

typedef StudioRunPhase = StudioPhaseItem;

class StudioRunPreview {
  const StudioRunPreview({
    required this.runId,
    required this.statusSummary,
    required this.phases,
    required this.workerCount,
    this.finalAnswer,
  });

  final String runId;
  final String statusSummary;
  final List<StudioPhaseItem> phases;
  final int workerCount;
  final String? finalAnswer;

  factory StudioRunPreview.fromJson(Map<String, dynamic> json) =>
      StudioRunPreview(
        runId: _string(json, 'runId'),
        statusSummary: _string(json, 'statusSummary'),
        phases: (json['phases'] as List? ?? const [])
            .map((item) => StudioPhaseItem.fromJson(
                Map<String, dynamic>.from(item as Map)))
            .toList(),
        workerCount: json['workerCount'] as int? ?? 1,
        finalAnswer: json['finalAnswer'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'runId': runId,
        'statusSummary': statusSummary,
        'phases': phases.map((p) => p.toJson()).toList(),
        'workerCount': workerCount,
        'finalAnswer': finalAnswer,
      };
}

class StudioChatMessage {
  const StudioChatMessage({
    required this.id,
    required this.sender,
    required this.text,
    required this.timestamp,
    this.runPreview,
  });

  final String id;
  final StudioMessageSender sender;
  final String text;
  final String timestamp;
  final StudioRunPreview? runPreview;

  factory StudioChatMessage.fromJson(Map<String, dynamic> json) =>
      StudioChatMessage(
        id: _string(json, 'id'),
        sender: StudioMessageSender.values.firstWhere(
          (v) => v.name == json['sender'],
          orElse: () => StudioMessageSender.conclave,
        ),
        text: _string(json, 'text'),
        timestamp: _string(json, 'timestamp'),
        runPreview: json['runPreview'] == null
            ? null
            : StudioRunPreview.fromJson(
                Map<String, dynamic>.from(json['runPreview'] as Map)),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'sender': sender.name,
        'text': text,
        'timestamp': timestamp,
        'runPreview': runPreview?.toJson(),
      };
}

class StudioChat {
  const StudioChat({
    required this.id,
    required this.projectId,
    required this.title,
    required this.lastActivity,
    required this.messages,
    this.activeRunId,
  });

  final String id;
  final String projectId;
  final String title;
  final String lastActivity;
  final List<StudioChatMessage> messages;
  final String? activeRunId;

  factory StudioChat.fromJson(Map<String, dynamic> json) => StudioChat(
        id: _string(json, 'id'),
        projectId: _string(json, 'projectId'),
        title: _string(json, 'title'),
        lastActivity: _string(json, 'lastActivity'),
        messages: (json['messages'] as List? ?? const [])
            .map((item) => StudioChatMessage.fromJson(
                Map<String, dynamic>.from(item as Map)))
            .toList(),
        activeRunId: json['activeRunId'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'title': title,
        'lastActivity': lastActivity,
        'messages': messages.map((m) => m.toJson()).toList(),
        'activeRunId': activeRunId,
      };
}

class StudioProject {
  const StudioProject({
    required this.id,
    required this.name,
    required this.repository,
    required this.branch,
    required this.activeGoals,
    required this.lastActivity,
    this.chats = const [],
  });

  final String id;
  final String name;
  final String repository;
  final String branch;
  final int activeGoals;
  final String lastActivity;
  final List<StudioChat> chats;

  factory StudioProject.fromJson(Map<String, dynamic> json) => StudioProject(
        id: _string(json, 'id'),
        name: _string(json, 'name'),
        repository: _string(json, 'repository'),
        branch: _string(json, 'branch'),
        activeGoals: json['activeGoals'] as int? ?? 0,
        lastActivity: _string(json, 'lastActivity'),
        chats: (json['chats'] as List? ?? const [])
            .map((item) =>
                StudioChat.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
      );
}

class StudioWorker {
  const StudioWorker({
    required this.id,
    required this.name,
    required this.provider,
    required this.role,
    required this.capabilities,
    required this.status,
    required this.cost,
    this.agentName = '—',
    this.pluginName = '—',
    this.roles = const [],
    this.agentId = '',
    this.pluginId = '',
    this.pluginVersionPolicy = 'latest',
    this.config = const {},
    this.sessionPolicy = 'stateless',
    this.concurrencyLimit = 1,
    this.billingMode = 'local_compute',
    this.independenceKey = '',
    this.costMetadata = const {},
  });

  final String id;
  final String name;
  final String provider;
  final String role;
  final List<String> capabilities;
  final String status;
  final String cost;
  final String agentName;
  final String pluginName;
  final List<String> roles;
  final String agentId;
  final String pluginId;
  final String pluginVersionPolicy;
  final Map<String, dynamic> config;
  final String sessionPolicy;
  final int concurrencyLimit;
  final String billingMode;
  final String independenceKey;
  final Map<String, dynamic> costMetadata;

  factory StudioWorker.fromJson(Map<String, dynamic> json) => StudioWorker(
      id: _string(json, 'id'),
      name: _string(json, 'name'),
      provider: _string(json, 'provider'),
      role: _string(json, 'role'),
      capabilities: _strings(json, 'capabilities'),
      status: _string(json, 'status'),
      cost: _string(json, 'cost'),
      agentName: _string(json, 'agentName'),
      pluginName: _string(json, 'pluginName'),
      roles: _strings(json, 'roles'),
      agentId: _string(json, 'agentId'),
      pluginId: _string(json, 'pluginId'),
      pluginVersionPolicy: _string(json, 'pluginVersionPolicy', 'latest'),
      config: _map(json, 'config'),
      sessionPolicy: _string(json, 'sessionPolicy', 'stateless'),
      concurrencyLimit: json['concurrencyLimit'] as int? ?? 1,
      billingMode: _string(json, 'billingMode', 'local_compute'),
      independenceKey: _string(json, 'independenceKey', ''),
      costMetadata: _map(json, 'costMetadata'));
}

class StudioAgent {
  const StudioAgent({
    required this.id,
    required this.name,
    required this.hostname,
    required this.status,
    required this.version,
    required this.pluginCount,
    required this.workerCount,
    required this.activeTaskCount,
    this.os = '—',
    this.architecture = '—',
    this.appVersion = '—',
    this.updateChannel = '—',
    this.lastSeen = '—',
  });

  final String id;
  final String name;
  final String hostname;
  final String status;
  final String version;
  final int pluginCount;
  final int workerCount;
  final int activeTaskCount;
  final String os;
  final String architecture;
  final String appVersion;
  final String updateChannel;
  final String lastSeen;

  factory StudioAgent.fromJson(Map<String, dynamic> json) => StudioAgent(
        id: _string(json, 'id'),
        name: _string(json, 'name'),
        hostname: _string(json, 'hostname'),
        status: _string(json, 'status'),
        version: _string(json, 'version'),
        pluginCount: json['pluginCount'] as int? ?? 0,
        workerCount: json['workerCount'] as int? ?? 0,
        activeTaskCount: json['activeTaskCount'] as int? ?? 0,
        os: _string(json, 'os'),
        architecture: _string(json, 'architecture'),
        appVersion: _string(json, 'appVersion'),
        updateChannel: _string(json, 'updateChannel'),
        lastSeen: _string(json, 'lastSeen'),
      );
}

class StudioPlugin {
  const StudioPlugin({
    required this.id,
    required this.name,
    required this.version,
    required this.status,
    required this.roles,
    required this.capabilities,
    this.description = '',
    this.publisher = '',
    this.channel = '—',
    this.permissions = const [],
    this.supportedOS = const [],
    this.supportedArchitecture = const [],
    this.installedAgentCount = 0,
  });

  final String id;
  final String name;
  final String version;
  final String status;
  final List<String> roles;
  final List<String> capabilities;
  final String description;
  final String publisher;
  final String channel;
  final List<String> permissions;
  final List<String> supportedOS;
  final List<String> supportedArchitecture;
  final int installedAgentCount;

  factory StudioPlugin.fromJson(Map<String, dynamic> json) => StudioPlugin(
        id: _string(json, 'id'),
        name: _string(json, 'name'),
        version: _string(json, 'version'),
        status: _string(json, 'status'),
        roles: _strings(json, 'roles'),
        capabilities: _strings(json, 'capabilities'),
        description: _string(json, 'description'),
        publisher: _string(json, 'publisher'),
        channel: _string(json, 'channel'),
        permissions: _strings(json, 'permissions'),
        supportedOS: _strings(json, 'supportedOS'),
        supportedArchitecture: _strings(json, 'supportedArchitecture'),
        installedAgentCount: json['installedAgentCount'] as int? ?? 0,
      );
}

class StudioTask {
  const StudioTask({
    required this.id,
    required this.title,
    required this.phase,
    required this.status,
    required this.worker,
    required this.detail,
    required this.progress,
    required this.dependencies,
    required this.tokens,
    required this.cost,
  });

  final String id;
  final String title;
  final String phase;
  final TaskStatus status;
  final String worker;
  final String detail;
  final double progress;
  final List<String> dependencies;
  final String tokens;
  final String cost;

  factory StudioTask.fromJson(Map<String, dynamic> json) => StudioTask(
      id: _string(json, 'id'),
      title: _string(json, 'title'),
      phase: _string(json, 'phase'),
      status: TaskStatus.values.firstWhere(
          (value) => value.name == json['status'],
          orElse: () => TaskStatus.pending),
      worker: _string(json, 'worker'),
      detail: _string(json, 'detail'),
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      dependencies: _strings(json, 'dependencies'),
      tokens: _string(json, 'tokens'),
      cost: _string(json, 'cost'));
}

class StudioFinding {
  const StudioFinding({
    required this.id,
    required this.title,
    required this.description,
    required this.severity,
    required this.status,
    required this.taskId,
    required this.author,
  });

  final String id;
  final String title;
  final String description;
  final FindingSeverity severity;
  final FindingStatus status;
  final String taskId;
  final String author;

  factory StudioFinding.fromJson(Map<String, dynamic> json) => StudioFinding(
      id: _string(json, 'id'),
      title: _string(json, 'title'),
      description: _string(json, 'description'),
      severity: FindingSeverity.values.firstWhere(
          (value) => value.name == json['severity'],
          orElse: () => FindingSeverity.note),
      status: FindingStatus.values.firstWhere(
          (value) => value.name == json['status'],
          orElse: () => FindingStatus.open),
      taskId: _string(json, 'taskId'),
      author: _string(json, 'author'));
}

class StudioEvent {
  const StudioEvent({
    required this.time,
    required this.title,
    required this.detail,
    required this.kind,
  });

  final String time;
  final String title;
  final String detail;
  final String kind;

  factory StudioEvent.fromJson(Map<String, dynamic> json) => StudioEvent(
      time: _string(json, 'time'),
      title: _string(json, 'title'),
      detail: _string(json, 'detail'),
      kind: _string(json, 'kind'));
}

class StudioArtifact {
  const StudioArtifact({
    required this.name,
    required this.type,
    required this.size,
    required this.source,
  });

  final String name;
  final String type;
  final String size;
  final String source;

  factory StudioArtifact.fromJson(Map<String, dynamic> json) => StudioArtifact(
      name: _string(json, 'name'),
      type: _string(json, 'type'),
      size: _string(json, 'size'),
      source: _string(json, 'source'));
}

class StudioModelCall {
  const StudioModelCall({
    required this.worker,
    required this.model,
    required this.task,
    required this.tokens,
    required this.cost,
    required this.duration,
    required this.status,
  });

  final String worker;
  final String model;
  final String task;
  final String tokens;
  final String cost;
  final String duration;
  final String status;

  factory StudioModelCall.fromJson(Map<String, dynamic> json) =>
      StudioModelCall(
          worker: _string(json, 'worker'),
          model: _string(json, 'model'),
          task: _string(json, 'task'),
          tokens: _string(json, 'tokens'),
          cost: _string(json, 'cost'),
          duration: _string(json, 'duration'),
          status: _string(json, 'status'));
}

class StudioRun {
  const StudioRun({
    required this.id,
    required this.status,
    required this.objective,
    required this.taskCount,
    required this.completedTaskCount,
    required this.openFindingCount,
    required this.verifiedCriterionCount,
    required this.criterionCount,
    required this.tokens,
    required this.costMicros,
  });

  final String id;
  final RunStatus status;
  final String objective;
  final int taskCount;
  final int completedTaskCount;
  final int openFindingCount;
  final int verifiedCriterionCount;
  final int criterionCount;
  final int tokens;
  final int costMicros;

  factory StudioRun.fromJson(Map<String, dynamic> json) => StudioRun(
        id: _string(json, 'id'),
        status: RunStatus.values.firstWhere(
          (value) => value.name == json['status'],
          orElse: () => RunStatus.running,
        ),
        objective: _string(json, 'objective'),
        taskCount: json['taskCount'] as int? ?? 0,
        completedTaskCount: json['completedTaskCount'] as int? ?? 0,
        openFindingCount: json['openFindingCount'] as int? ?? 0,
        verifiedCriterionCount: json['verifiedCriterionCount'] as int? ?? 0,
        criterionCount: json['criterionCount'] as int? ?? 0,
        tokens: json['tokens'] as int? ?? 0,
        costMicros: json['costMicros'] as int? ?? 0,
      );
}

class StudioViewer {
  const StudioViewer({
    required this.id,
    required this.displayName,
    required this.email,
  });

  final String id;
  final String displayName;
  final String email;

  factory StudioViewer.fromJson(Map<String, dynamic> json) => StudioViewer(
        id: _string(json, 'id'),
        displayName: _string(json, 'displayName'),
        email: _string(json, 'email'),
      );
}

class StudioSession {
  const StudioSession({
    required this.authenticated,
    this.viewer,
    this.workspaceId,
    this.workspaceRole,
  });

  final bool authenticated;
  final StudioViewer? viewer;
  final String? workspaceId;
  final String? workspaceRole;

  factory StudioSession.fromJson(Map<String, dynamic> json) => StudioSession(
        authenticated: json['authenticated'] == true,
        viewer: json['user'] is Map
            ? StudioViewer.fromJson(
                Map<String, dynamic>.from(json['user'] as Map))
            : null,
        workspaceId: json['workspaceId'] as String?,
        workspaceRole: json['workspaceRole'] as String?,
      );
}

class StudioWorkspace {
  const StudioWorkspace({
    required this.id,
    required this.name,
    required this.slug,
    required this.status,
    required this.role,
  });

  final String id;
  final String name;
  final String slug;
  final String status;
  final String role;

  factory StudioWorkspace.fromJson(Map<String, dynamic> json) =>
      StudioWorkspace(
        id: _string(json, 'id'),
        name: _string(json, 'name'),
        slug: _string(json, 'slug'),
        status: _string(json, 'status', 'active'),
        role: _string(json, 'role', 'viewer'),
      );
}

class StudioSnapshot {
  const StudioSnapshot({
    this.workspaceId,
    this.viewer,
    this.activeRunId,
    this.activeChatId,
    this.run,
    required this.projects,
    required this.workers,
    this.agents = const [],
    this.plugins = const [],
    required this.tasks,
    required this.findings,
    required this.events,
    required this.artifacts,
    required this.modelCalls,
    this.policy,
    this.candidateOutputs = const [],
    this.synthesisDecision,
  });

  final String? workspaceId;
  final String? activeRunId;
  final StudioViewer? viewer;
  final String? activeChatId;
  final StudioRun? run;
  final List<StudioProject> projects;
  final List<StudioWorker> workers;
  final List<StudioAgent> agents;
  final List<StudioPlugin> plugins;
  final List<StudioTask> tasks;
  final List<StudioFinding> findings;
  final List<StudioEvent> events;
  final List<StudioArtifact> artifacts;
  final List<StudioModelCall> modelCalls;
  final StudioPolicy? policy;
  final List<StudioCandidateOutput> candidateOutputs;
  final StudioSynthesisDecision? synthesisDecision;

  List<StudioChat> get allChats =>
      projects.expand((project) => project.chats).toList();

  StudioChat? get activeChat {
    final chats = allChats;
    if (activeChatId != null) {
      final found = chats.where((c) => c.id == activeChatId).firstOrNull;
      if (found != null) return found;
    }
    return chats.firstOrNull;
  }

  static StudioSnapshot empty() => const StudioSnapshot(
      projects: [],
      workers: [],
      agents: [],
      plugins: [],
      tasks: [],
      findings: [],
      events: [],
      artifacts: [],
      modelCalls: []);

  factory StudioSnapshot.fromJson(Map<String, dynamic> json) => StudioSnapshot(
        workspaceId: json['workspaceId'] as String?,
        viewer: json['viewer'] == null
            ? null
            : StudioViewer.fromJson(
                Map<String, dynamic>.from(json['viewer'] as Map)),
        activeRunId: json['activeRunId'] as String?,
        activeChatId: json['activeChatId'] as String?,
        run: json['run'] == null
            ? null
            : StudioRun.fromJson(Map<String, dynamic>.from(json['run'] as Map)),
        projects: (json['projects'] as List? ?? const [])
            .map((item) =>
                StudioProject.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        workers: (json['workers'] as List? ?? const [])
            .map((item) =>
                StudioWorker.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        agents: (json['agents'] as List? ?? const [])
            .map((item) =>
                StudioAgent.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        plugins: (json['plugins'] as List? ?? const [])
            .map((item) =>
                StudioPlugin.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        tasks: (json['tasks'] as List? ?? const [])
            .map((item) =>
                StudioTask.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        findings: (json['findings'] as List? ?? const [])
            .map((item) =>
                StudioFinding.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        events: (json['events'] as List? ?? const [])
            .map((item) =>
                StudioEvent.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        artifacts: (json['artifacts'] as List? ?? const [])
            .map((item) =>
                StudioArtifact.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        modelCalls: (json['modelCalls'] as List? ?? const [])
            .map((item) => StudioModelCall.fromJson(
                Map<String, dynamic>.from(item as Map)))
            .toList(),
        policy: json['policy'] == null
            ? null
            : StudioPolicy.fromJson(
                Map<String, dynamic>.from(json['policy'] as Map)),
        candidateOutputs: (json['candidateOutputs'] as List? ?? const [])
            .map((item) => StudioCandidateOutput.fromJson(
                Map<String, dynamic>.from(item as Map)))
            .toList(),
        synthesisDecision: json['synthesisDecision'] == null
            ? null
            : StudioSynthesisDecision.fromJson(
                Map<String, dynamic>.from(json['synthesisDecision'] as Map)),
      );
}
