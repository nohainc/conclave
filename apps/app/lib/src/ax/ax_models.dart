import 'worker_execution_options.dart';
export 'worker_execution_options.dart';
import 'dart:convert';

enum RunStatus {
  active,
  running,
  waiting,
  paused,
  completed,
  failed,
  cancelled
}

enum TaskStatus {
  completed,
  running,
  ready,
  blocked,
  pending,
  failed,
  cancelled
}

extension TaskStatusHelpers on TaskStatus {
  bool get isCompleted => this == TaskStatus.completed;
  bool get isRunning => this == TaskStatus.running;
  bool get isBlocked => this == TaskStatus.blocked;
  bool get isFailed =>
      this == TaskStatus.failed || this == TaskStatus.cancelled;
  bool get isPending => this == TaskStatus.pending || this == TaskStatus.ready;
  String get label => switch (this) {
        TaskStatus.completed => 'Completed',
        TaskStatus.failed => 'Failed',
        TaskStatus.cancelled => 'Cancelled',
        TaskStatus.running => 'Running',
        TaskStatus.ready => 'Ready',
        TaskStatus.blocked => 'Blocked',
        TaskStatus.pending => 'Pending',
      };
}

extension AxTaskHelpers on AxTask {
  bool get isCompleted => status.isCompleted;
  bool get isRunning => status.isRunning;
  bool get isFailed => status.isFailed || status == TaskStatus.blocked;
  String get stage => phase.isNotEmpty ? phase : 'Execution';
  String? get assignedWorkerId => worker.isNotEmpty ? worker : null;
}

extension AxProjectHelpers on AxProject {
  String get title => name;
}

enum FindingSeverity { blocker, major, minor, note }

enum FindingStatus { open, fixed, verified }

class AxCandidateOutput {
  const AxCandidateOutput({
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

  factory AxCandidateOutput.fromJson(Map<String, dynamic> json) =>
      AxCandidateOutput(
        worker: _string(json, 'worker'),
        role: _string(json, 'role'),
        status: _string(json, 'status'),
        summary: _string(json, 'summary'),
        artifactCount: json['artifactCount'] as int? ?? 0,
      );
}

class AxSynthesisDecision {
  const AxSynthesisDecision({
    required this.status,
    required this.summary,
    required this.worker,
    required this.evidence,
  });

  final String status;
  final String summary;
  final String worker;
  final String evidence;

  factory AxSynthesisDecision.fromJson(Map<String, dynamic> json) =>
      AxSynthesisDecision(
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

class AxWorkflowCapabilities {
  const AxWorkflowCapabilities({
    this.userSelectsWorker = false,
    this.userSelectsModel = false,
    this.userSelectsEffort = false,
    this.multiStep = false,
    this.multiWorker = false,
    this.automaticContinuation = false,
    this.requiresApprovalBetweenSteps = false,
  });

  final bool userSelectsWorker;
  final bool userSelectsModel;
  final bool userSelectsEffort;
  final bool multiStep;
  final bool multiWorker;
  final bool automaticContinuation;
  final bool requiresApprovalBetweenSteps;

  factory AxWorkflowCapabilities.fromJson(Map<String, dynamic> json) =>
      AxWorkflowCapabilities(
        userSelectsWorker: json['userSelectsWorker'] == true,
        userSelectsModel: json['userSelectsModel'] == true,
        userSelectsEffort: json['userSelectsEffort'] == true,
        multiStep: json['multiStep'] == true,
        multiWorker: json['multiWorker'] == true,
        automaticContinuation: json['automaticContinuation'] == true,
        requiresApprovalBetweenSteps:
            json['requiresApprovalBetweenSteps'] == true,
      );
}

class AxBuiltinWorkflow {
  const AxBuiltinWorkflow({
    required this.id,
    required this.version,
    required this.name,
    required this.description,
    required this.steps,
    required this.snapshot,
    this.executionPolicy = const AxWorkflowCapabilities(),
    this.composerBindingId,
  });

  final String id;
  final int version;
  final String name;
  final String description;
  final List<AxBuiltinWorkflowStep> steps;
  final Map<String, dynamic> snapshot;
  final AxWorkflowCapabilities executionPolicy;
  final String? composerBindingId;
  String get reference => '$id:v$version';

  factory AxBuiltinWorkflow.fromJson(Map<String, dynamic> json) =>
      AxBuiltinWorkflow(
        id: _string(json, 'id', ''),
        version: json['version'] as int? ?? 1,
        name: _string(json, 'name', ''),
        description: _string(json, 'description', ''),
        steps: (json['steps'] as List? ?? const [])
            .whereType<Map>()
            .map((step) =>
                AxBuiltinWorkflowStep.fromJson(Map<String, dynamic>.from(step)))
            .toList(),
        executionPolicy: AxWorkflowCapabilities.fromJson(
          json['executionPolicy'] is Map
              ? Map<String, dynamic>.from(json['executionPolicy'] as Map)
              : const {},
        ),
        composerBindingId: json['composerBindingId'] as String?,
        snapshot: Map<String, dynamic>.from(json)
          ..remove('executionPolicy')
          ..remove('composerBindingId'),
      );
}

class AxBuiltinWorkflowStep {
  const AxBuiltinWorkflowStep({
    required this.kind,
    required this.order,
  });

  final String kind;
  final int order;

  factory AxBuiltinWorkflowStep.fromJson(Map<String, dynamic> json) =>
      AxBuiltinWorkflowStep(
        kind: _string(json, 'kind', ''),
        order: json['order'] as int? ?? 0,
      );
}

List<String> _strings(Map<String, dynamic> json, String key) =>
    List<String>.from(json[key] as List? ?? const []);

List<String> _runtimeCapabilityLabels(Map<String, dynamic> json, String key) {
  dynamic value = json[key];
  if (value is String) {
    try {
      value = jsonDecode(value);
    } catch (_) {
      return const [];
    }
  }
  if (value is List) return value.whereType<String>().toList();
  if (value is! Map) return const [];

  final labels = (value['supportedRuntimes'] as List? ?? const [])
      .whereType<String>()
      .toList();
  final maxConcurrentWorkers = value['maxConcurrentWorkers'];
  if (maxConcurrentWorkers is int) {
    labels.add('Up to $maxConcurrentWorkers concurrent Workers');
  }
  return labels;
}

enum AxPhaseStatus { completed, inProgress, pending }

class AxPhaseItem {
  const AxPhaseItem({
    required this.name,
    required this.status,
    this.detail,
  });

  final String name;
  final AxPhaseStatus status;
  final String? detail;

  factory AxPhaseItem.fromJson(Map<String, dynamic> json) => AxPhaseItem(
        name: _string(json, 'name'),
        status: AxPhaseStatus.values.firstWhere(
          (v) => v.name == json['status'],
          orElse: () => AxPhaseStatus.pending,
        ),
        detail: json['detail'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'status': status.name,
        'detail': detail,
      };
}

typedef AxRunPhase = AxPhaseItem;

class AxWorkstream {
  const AxWorkstream({
    required this.id,
    required this.projectId,
    required this.name,
    required this.lead,
    required this.status,
    required this.brief,
    required this.primaryWorkspace,
    required this.queueStatus,
    this.workConfig = const {},
    this.canConfigureWork = false,
    this.canExecuteWork = false,
    this.archived = false,
  });

  final String id;
  final String projectId;
  final String name;
  final String lead;
  final String status;
  final String brief;
  final String primaryWorkspace;
  final String queueStatus;
  final Map<String, dynamic> workConfig;
  final bool canConfigureWork;
  final bool canExecuteWork;
  final bool archived;

  AxWorkstream copyWith(
          {String? name, String? status, Map<String, dynamic>? workConfig}) =>
      AxWorkstream(
          id: id,
          projectId: projectId,
          name: name ?? this.name,
          lead: lead,
          status: status ?? this.status,
          brief: brief,
          primaryWorkspace: primaryWorkspace,
          queueStatus: queueStatus,
          workConfig: workConfig ?? this.workConfig,
          canConfigureWork: canConfigureWork,
          canExecuteWork: canExecuteWork,
          archived: status == null ? archived : status == 'archived');

  factory AxWorkstream.fromJson(Map<String, dynamic> json) => AxWorkstream(
        id: _string(json, 'id'),
        projectId: _string(json, 'projectId'),
        name: _string(json, 'name'),
        lead: _string(json, 'lead', _string(json, 'leadName', 'Unassigned')),
        status: _string(json, 'status', 'active'),
        brief: _string(json, 'brief', ''),
        primaryWorkspace: _string(json, 'primaryWorkspace', 'Not selected'),
        queueStatus: _string(json, 'queueStatus', 'Idle'),
        workConfig: json['workConfig'] is Map
            ? Map<String, dynamic>.from(json['workConfig'] as Map)
            : const {},
        canConfigureWork: json['canConfigureWork'] == true,
        canExecuteWork: json['canExecuteWork'] == true,
        archived: json['archived'] == true,
      );
}

/// Discussion paging contract 1. Messages are in chronological display order.
class AxDiscussionPage {
  AxDiscussionPage(
      {required Iterable<AxDiscussionMessage> messages,
      this.nextCursor,
      this.newestCursor})
      : messages = List.unmodifiable(messages);
  final List<AxDiscussionMessage> messages;
  final String? nextCursor;
  final String? newestCursor;
}

class AxDiscussionMessage {
  const AxDiscussionMessage({
    required this.id,
    required this.workstreamId,
    required this.authorUserId,
    this.authorName,
    required this.body,
    this.references = const [],
    this.editedAt,
    required this.createdAt,
    this.isMe = false,
  });

  final String id;
  final String workstreamId;
  final String authorUserId;
  final String? authorName;
  final String body;
  final List<String> references;
  final String? editedAt;
  final String createdAt;
  final bool isMe;

  AxDiscussionMessage copyWith({String? id, String? body, String? editedAt}) =>
      AxDiscussionMessage(
          id: id ?? this.id,
          workstreamId: workstreamId,
          authorUserId: authorUserId,
          authorName: authorName,
          body: body ?? this.body,
          references: references,
          editedAt: editedAt ?? this.editedAt,
          createdAt: createdAt,
          isMe: isMe);

  factory AxDiscussionMessage.fromJson(
    Map<String, dynamic> json, {
    String? currentUserId,
    Map<String, String>? memberNames,
  }) {
    final authorId =
        _string(json, 'authorUserId', _string(json, 'author_user_id'));
    final author = memberNames?[authorId] ??
        (json['authorName'] as String? ??
            (json['author_name'] as String? ??
                (authorId.isNotEmpty ? authorId : 'Member')));
    final rawRefs = json['references'];
    final refs = rawRefs is List
        ? rawRefs.map((e) => e.toString()).toList()
        : <String>[];
    return AxDiscussionMessage(
      id: _string(json, 'id'),
      workstreamId:
          _string(json, 'workstreamId', _string(json, 'workstream_id')),
      authorUserId: authorId,
      authorName: author,
      body: _string(json, 'body', _string(json, 'content')),
      references: refs,
      editedAt: json['editedAt'] as String? ?? json['edited_at'] as String?,
      createdAt: _string(json, 'createdAt', _string(json, 'created_at')),
      isMe: currentUserId != null &&
          currentUserId.isNotEmpty &&
          authorId == currentUserId,
    );
  }
}

class AxProject {
  const AxProject({
    required this.id,
    required this.name,
    required this.branch,
    required this.lastActivity,
    this.workstreams = const [],
    this.description = '',
    this.instructions = '',
    this.archived = false,
    this.role = 'owner',
    this.settings = const {},
  });

  final String id;
  final String name;
  final String branch;
  final String lastActivity;
  final List<AxWorkstream> workstreams;
  final String description;
  final String instructions;
  final bool archived;
  final String role;
  final Map<String, dynamic> settings;

  factory AxProject.fromJson(Map<String, dynamic> json) => AxProject(
        id: _string(json, 'id'),
        name: _string(json, 'name'),
        branch: _string(json, 'branch'),
        lastActivity: _string(json, 'lastActivity'),
        workstreams: (json['workstreams'] as List? ?? const [])
            .map((item) =>
                AxWorkstream.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        description: _string(json, 'description', ''),
        instructions: _string(
            json,
            'instructions',
            (json['settings'] is Map &&
                    (json['settings'] as Map)['instructions'] != null)
                ? (json['settings'] as Map)['instructions'].toString()
                : ''),
        archived: json['archived'] == true ||
            (json['settings'] is Map &&
                (json['settings'] as Map)['archived'] == true),
        role: _string(json, 'role', 'owner'),
        settings: json['settings'] is Map
            ? Map<String, dynamic>.from(json['settings'] as Map)
            : const {},
      );

  AxProject copyWith({
    String? id,
    String? name,
    String? branch,
    String? lastActivity,
    List<AxWorkstream>? workstreams,
    String? description,
    String? instructions,
    bool? archived,
    String? role,
    Map<String, dynamic>? settings,
  }) =>
      AxProject(
        id: id ?? this.id,
        name: name ?? this.name,
        branch: branch ?? this.branch,
        lastActivity: lastActivity ?? this.lastActivity,
        workstreams: workstreams ?? this.workstreams,
        description: description ?? this.description,
        instructions: instructions ?? this.instructions,
        archived: archived ?? this.archived,
        role: role ?? this.role,
        settings: settings ?? this.settings,
      );
}

/// Safe Cloud projection of a locally owned Workspace Worker.
/// It intentionally contains no credential references, secrets, or local paths.
class AxWorker {
  const AxWorker({
    required this.id,
    required this.workspaceId,
    required this.workspaceName,
    required this.workerTypeId,
    required this.displayName,
    this.description,
    this.catalogLifecycleState = 'active',
    this.catalogVisibilityState = 'visible',
    required this.status,
    required this.readinessState,
    this.activationState = 'enabled',
    this.attentionReasonCode,
    required this.localConcurrencyLimit,
    required this.capabilities,
    this.inputCapabilities = const [],
    this.engineVersion,
    this.profileDefinitionId,
    this.profileReleaseVersion,
    this.providerToolName,
    this.providerToolVersion,
    this.modelOptions = const {},
    this.executionOptions,
  });

  final String id;
  final String workspaceId;
  final String workspaceName;
  final String workerTypeId;
  final String displayName;
  final String? description;
  final String catalogLifecycleState;
  final String catalogVisibilityState;
  final String status;
  final String readinessState;
  final String activationState;
  bool get isReady =>
      activationState == 'enabled' &&
      readinessState == 'ready' &&
      catalogLifecycleState == 'active' &&
      catalogVisibilityState == 'visible';
  final String? attentionReasonCode;
  final int localConcurrencyLimit;
  final String? engineVersion;
  final String? profileDefinitionId;
  final int? profileReleaseVersion;
  final String? providerToolName;
  final String? providerToolVersion;
  final Map<String, dynamic> modelOptions;
  final AxWorkerExecutionOptions? executionOptions;
  final List<String> capabilities;
  final List<String> inputCapabilities;

  factory AxWorker.fromJson(Map<String, dynamic> json) => AxWorker(
        executionOptions: json['executionOptions'] is Map
            ? AxWorkerExecutionOptions.fromJson(
                Map<String, dynamic>.from(json['executionOptions'] as Map))
            : null,
        modelOptions: json['modelOptions'] is Map
            ? Map<String, dynamic>.from(json['modelOptions'] as Map)
            : const {},
        id: _string(json, 'id'),
        workspaceId: _string(json, 'workspaceId'),
        workspaceName: _string(json, 'workspaceName'),
        workerTypeId: _string(json, 'workerTypeId'),
        displayName: _string(json, 'displayName'),
        description: json['description']?.toString(),
        catalogLifecycleState: _string(json, 'catalogLifecycleState', 'active'),
        catalogVisibilityState:
            _string(json, 'catalogVisibilityState', 'visible'),
        status: json['activationState'] == 'disabled'
            ? 'disabled'
            : json['readinessState'] == 'ready'
                ? 'ready'
                : 'needs_attention',
        readinessState: _string(json, 'readinessState', 'test_failed'),
        activationState: _string(json, 'activationState', 'enabled'),
        attentionReasonCode: json['readinessIssueCode']?.toString() ??
            json['attentionReasonCode']?.toString(),
        localConcurrencyLimit: json['localConcurrencyLimit'] as int? ?? 1,
        engineVersion: json['engineVersion']?.toString(),
        profileDefinitionId: json['profileDefinitionId']?.toString(),
        profileReleaseVersion: json['profileReleaseVersion'] as int?,
        providerToolName: json['providerToolName']?.toString(),
        providerToolVersion: json['providerToolVersion']?.toString(),
        capabilities: _strings(json, 'capabilities'),
        inputCapabilities: _strings(json, 'inputCapabilities'),
      );
}

class AxTask {
  const AxTask({
    required this.id,
    required this.title,
    required this.phase,
    required this.status,
    required this.worker,
    required this.detail,
    required this.progress,
    required this.dependencies,
    this.errorCode,
    this.errorMessage,
  });

  final String id;
  final String title;
  final String phase;
  final TaskStatus status;
  final String worker;
  final String detail;
  final double progress;
  final List<String> dependencies;
  final String? errorCode;
  final String? errorMessage;

  factory AxTask.fromJson(Map<String, dynamic> json) => AxTask(
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
      errorCode:
          json['errorCode'] is String ? json['errorCode'] as String : null,
      errorMessage: json['errorMessage'] is String
          ? json['errorMessage'] as String
          : null);
}

class AxFinding {
  const AxFinding({
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

  factory AxFinding.fromJson(Map<String, dynamic> json) => AxFinding(
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

class AxEvent {
  const AxEvent({
    required this.time,
    required this.title,
    required this.detail,
    required this.kind,
    this.eventId,
    this.correlationId,
  });

  final String time;
  final String title;
  final String detail;
  final String kind;
  final String? eventId;
  final String? correlationId;

  factory AxEvent.fromJson(Map<String, dynamic> json) => AxEvent(
      time: _string(json, 'time'),
      title: _string(json, 'title'),
      detail: _string(json, 'detail'),
      kind: _string(json, 'kind'),
      eventId: json['eventId'] as String?,
      correlationId: json['correlationId'] as String?);
}

class AxArtifact {
  const AxArtifact({
    required this.name,
    required this.type,
    required this.size,
    required this.source,
  });

  final String name;
  final String type;
  final String size;
  final String source;

  factory AxArtifact.fromJson(Map<String, dynamic> json) => AxArtifact(
      name: _string(json, 'name'),
      type: _string(json, 'type'),
      size: _string(json, 'size'),
      source: _string(json, 'source'));
}

class AxRun {
  const AxRun({
    required this.id,
    this.workstreamId,
    required this.status,
    required this.objective,
    required this.taskCount,
    required this.completedTaskCount,
    required this.openFindingCount,
    required this.verifiedCriterionCount,
    required this.criterionCount,
  });

  final String id;
  final String? workstreamId;
  final RunStatus status;
  final String objective;
  final int taskCount;
  final int completedTaskCount;
  final int openFindingCount;
  final int verifiedCriterionCount;
  final int criterionCount;

  factory AxRun.fromJson(Map<String, dynamic> json) => AxRun(
        id: _string(json, 'id'),
        workstreamId: json['workstreamId'] as String?,
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
      );
}

class AxViewer {
  const AxViewer({
    required this.id,
    required this.displayName,
    required this.email,
  });

  final String id;
  final String displayName;
  final String email;

  factory AxViewer.fromJson(Map<String, dynamic> json) => AxViewer(
        id: _string(json, 'id'),
        displayName: _string(json, 'displayName'),
        email: _string(json, 'email'),
      );
}

class AxSession {
  const AxSession({
    required this.authenticated,
    this.viewer,
  });

  final bool authenticated;
  final AxViewer? viewer;
  factory AxSession.fromJson(Map<String, dynamic> json) => AxSession(
        authenticated: json['authenticated'] == true,
        viewer: json['user'] is Map
            ? AxViewer.fromJson(Map<String, dynamic>.from(json['user'] as Map))
            : null,
      );
}

class AxAuthAccount {
  const AxAuthAccount({
    required this.id,
    required this.providerId,
    required this.accountId,
  });

  final String id;
  final String providerId;
  final String accountId;

  factory AxAuthAccount.fromJson(Map<String, dynamic> json) => AxAuthAccount(
        id: _string(json, 'id'),
        providerId: _string(json, 'providerId', _string(json, 'provider_id')),
        accountId: _string(json, 'accountId', _string(json, 'account_id')),
      );
}

class AxAuthSession {
  const AxAuthSession({
    required this.token,
    required this.createdAt,
    required this.expiresAt,
    this.userAgent,
    this.ipAddress,
  });

  final String token;
  final String createdAt;
  final String expiresAt;
  final String? userAgent;
  final String? ipAddress;

  factory AxAuthSession.fromJson(Map<String, dynamic> json) => AxAuthSession(
        token: _string(json, 'token'),
        createdAt: _string(json, 'createdAt', _string(json, 'created_at')),
        expiresAt: _string(json, 'expiresAt', _string(json, 'expires_at')),
        userAgent:
            json['userAgent'] as String? ?? json['user_agent'] as String?,
        ipAddress:
            json['ipAddress'] as String? ?? json['ip_address'] as String?,
      );
}

class AxAccountSecurity {
  const AxAccountSecurity({
    required this.accounts,
    required this.sessions,
    this.passkeys = const [],
  });

  final List<AxAuthAccount> accounts;
  final List<AxAuthSession> sessions;
  final List<AxPasskey> passkeys;

  factory AxAccountSecurity.fromJson(List<Map<String, dynamic>> accounts,
          List<Map<String, dynamic>> sessions,
          [List<Map<String, dynamic>> passkeys = const []]) =>
      AxAccountSecurity(
        accounts: accounts.map(AxAuthAccount.fromJson).toList(growable: false),
        sessions: sessions.map(AxAuthSession.fromJson).toList(growable: false),
        passkeys: passkeys.map(AxPasskey.fromJson).toList(growable: false),
      );
}

class AxPasskey {
  const AxPasskey({
    required this.id,
    required this.name,
    required this.createdAt,
    this.aaguid,
  });

  final String id;
  final String name;
  final String createdAt;
  final String? aaguid;

  factory AxPasskey.fromJson(Map<String, dynamic> json) => AxPasskey(
        id: _string(json, 'id'),
        name: _string(json, 'name', 'Passkey'),
        createdAt: _string(json, 'createdAt', _string(json, 'created_at')),
        aaguid: json['aaguid'] as String?,
      );
}

class AxWorkspace {
  const AxWorkspace({
    required this.id,
    required this.name,
    this.slug = '',
    this.status = 'offline',
    this.role = 'owner',
    this.hasRuntimeIdentity = false,
    this.platform = '—',
    this.architecture = '—',
    this.hostname = '—',
    this.appVersion = '—',
    this.activeTransport,
    this.connectionMode,
    this.runtimeCapabilities = const [],
    this.factsUpdatedAt,
    this.updateChannel = 'stable',
    this.lastSeen = '—',
    this.workerCount = 0,
    this.activeTaskCount = 0,
    this.projectGrantCount = 0,
  });

  final String id;
  final String name;
  final String slug;
  final String status;
  final String role;
  final bool hasRuntimeIdentity;
  final String platform;
  final String architecture;
  final String hostname;
  final String appVersion;
  final String? activeTransport;
  final String? connectionMode;
  final List<String> runtimeCapabilities;
  final String? factsUpdatedAt;
  final String updateChannel;
  final String lastSeen;
  final int workerCount;
  final int activeTaskCount;
  final int projectGrantCount;

  factory AxWorkspace.fromJson(Map<String, dynamic> json) => AxWorkspace(
        id: _string(json, 'id'),
        name: _string(json, 'name'),
        slug: _string(json, 'slug'),
        status: _string(json, 'status', 'offline'),
        role: _string(json, 'role', 'viewer'),
        hasRuntimeIdentity: json['hasRuntimeIdentity'] == true ||
            json['hasRuntimeIdentity'] == 1,
        platform: _string(json, 'platform'),
        architecture: _string(json, 'architecture'),
        hostname: _string(json, 'hostname'),
        appVersion: _string(json, 'appVersion'),
        activeTransport: json['activeTransport']?.toString(),
        connectionMode: json['connectionMode']?.toString(),
        runtimeCapabilities:
            _runtimeCapabilityLabels(json, 'runtimeCapabilitiesJson'),
        factsUpdatedAt: json['factsUpdatedAt']?.toString(),
        updateChannel: _string(json, 'updateChannel', 'stable'),
        lastSeen: _string(
            json, 'lastSeen', json['factsUpdatedAt']?.toString() ?? '—'),
        workerCount: json['workerCount'] as int? ?? 0,
        activeTaskCount: json['activeTaskCount'] as int? ?? 0,
        projectGrantCount: (json['activeProjectGrantCount'] ??
                json['projectGrantCount']) as int? ??
            0,
      );

  AxWorkspace copyWith({
    int? workerCount,
    int? activeTaskCount,
    int? projectGrantCount,
    String? lastSeen,
  }) =>
      AxWorkspace(
        id: id,
        name: name,
        slug: slug,
        status: status,
        role: role,
        hasRuntimeIdentity: hasRuntimeIdentity,
        platform: platform,
        architecture: architecture,
        hostname: hostname,
        appVersion: appVersion,
        activeTransport: activeTransport,
        connectionMode: connectionMode,
        runtimeCapabilities: runtimeCapabilities,
        factsUpdatedAt: factsUpdatedAt,
        updateChannel: updateChannel,
        lastSeen: lastSeen ?? this.lastSeen,
        workerCount: workerCount ?? this.workerCount,
        activeTaskCount: activeTaskCount ?? this.activeTaskCount,
        projectGrantCount: projectGrantCount ?? this.projectGrantCount,
      );
}

class AxWorkspaceMember {
  const AxWorkspaceMember({
    required this.userId,
    required this.displayName,
    required this.email,
    required this.role,
    required this.status,
    required this.createdAt,
  });

  final String userId;
  final String displayName;
  final String email;
  final String role;
  final String status;
  final String createdAt;

  factory AxWorkspaceMember.fromJson(Map<String, dynamic> json) =>
      AxWorkspaceMember(
        userId: _string(json, 'userId'),
        displayName: _string(json, 'displayName', _string(json, 'email')),
        email: _string(json, 'email'),
        role: _string(json, 'role', 'member'),
        status: _string(json, 'status', 'active'),
        createdAt: _string(json, 'createdAt'),
      );
}

class AxWorkspaceInvitation {
  const AxWorkspaceInvitation({
    required this.id,
    required this.email,
    required this.role,
    required this.status,
    required this.expiresAt,
    required this.createdAt,
  });

  final String id;
  final String email;
  final String role;
  final String status;
  final String expiresAt;
  final String createdAt;

  factory AxWorkspaceInvitation.fromJson(Map<String, dynamic> json) =>
      AxWorkspaceInvitation(
        id: _string(json, 'id'),
        email: _string(json, 'email'),
        role: _string(json, 'role', 'member'),
        status: _string(json, 'status', 'pending'),
        expiresAt: _string(json, 'expiresAt'),
        createdAt: _string(json, 'createdAt'),
      );
}

class AxProjectMember {
  const AxProjectMember({
    required this.userId,
    required this.displayName,
    required this.email,
    required this.role,
    required this.createdAt,
  });

  final String userId;
  final String displayName;
  final String email;
  final String role;
  final String createdAt;

  factory AxProjectMember.fromJson(Map<String, dynamic> json) =>
      AxProjectMember(
        userId: _string(json, 'userId'),
        displayName: _string(json, 'displayName', _string(json, 'email')),
        email: _string(json, 'email'),
        role: _string(json, 'role', 'viewer'),
        createdAt: _string(json, 'createdAt'),
      );
}

class AxProjectInvitation {
  const AxProjectInvitation({
    required this.id,
    this.projectId = '',
    this.projectName = '',
    required this.email,
    required this.role,
    required this.status,
    this.invitedByUserId = '',
    this.invitedByUserName = '',
    this.invitedByUserEmail = '',
    this.expiresAt = '',
    required this.createdAt,
  });

  final String id;
  final String projectId;
  final String projectName;
  final String email;
  final String role;
  final String status;
  final String invitedByUserId;
  final String invitedByUserName;
  final String invitedByUserEmail;
  final String expiresAt;
  final String createdAt;

  String get invitedByDisplay {
    if (invitedByUserName.isNotEmpty) return invitedByUserName;
    if (invitedByUserEmail.isNotEmpty) return invitedByUserEmail;
    if (invitedByUserId.isNotEmpty) return invitedByUserId;
    return 'Unknown';
  }

  factory AxProjectInvitation.fromJson(Map<String, dynamic> json) =>
      AxProjectInvitation(
        id: _string(json, 'id'),
        projectId: _string(json, 'projectId'),
        projectName: _string(json, 'projectName'),
        email: _string(json, 'email'),
        role: _string(json, 'role', 'viewer'),
        status: _string(json, 'status', 'pending'),
        invitedByUserId: _string(json, 'invitedByUserId'),
        invitedByUserName: _string(json, 'invitedByUserName'),
        invitedByUserEmail: _string(json, 'invitedByUserEmail'),
        expiresAt: _string(json, 'expiresAt'),
        createdAt: _string(json, 'createdAt'),
      );
}

class AxAuditEntry {
  const AxAuditEntry({
    required this.id,
    required this.action,
    required this.targetType,
    required this.targetId,
    required this.createdAt,
  });

  final String id;
  final String action;
  final String targetType;
  final String targetId;
  final String createdAt;

  factory AxAuditEntry.fromJson(Map<String, dynamic> json) => AxAuditEntry(
        id: _string(json, 'id'),
        action: _string(json, 'action'),
        targetType: _string(json, 'targetType'),
        targetId: _string(json, 'targetId'),
        createdAt: _string(json, 'createdAt'),
      );
}

class AxSnapshot {
  const AxSnapshot({
    this.workspaceId,
    this.viewer,
    this.activeRunId,
    this.run,
    required this.projects,
    this.workspaces = const [],
    required this.tasks,
    required this.findings,
    required this.events,
    required this.artifacts,
    this.candidateOutputs = const [],
    this.synthesisDecision,
  });

  final String? workspaceId;
  final String? activeRunId;
  final AxViewer? viewer;
  final AxRun? run;
  final List<AxProject> projects;
  final List<AxWorkspace> workspaces;
  final List<AxTask> tasks;
  final List<AxFinding> findings;
  final List<AxEvent> events;
  final List<AxArtifact> artifacts;
  final List<AxCandidateOutput> candidateOutputs;
  final AxSynthesisDecision? synthesisDecision;

  AxSnapshot copyWith({
    List<AxProject>? projects,
    List<AxWorkspace>? workspaces,
  }) =>
      AxSnapshot(
        workspaceId: workspaceId,
        viewer: viewer,
        activeRunId: activeRunId,
        run: run,
        projects: projects ?? this.projects,
        workspaces: workspaces ?? this.workspaces,
        tasks: tasks,
        findings: findings,
        events: events,
        artifacts: artifacts,
        candidateOutputs: candidateOutputs,
        synthesisDecision: synthesisDecision,
      );

  static AxSnapshot empty() => const AxSnapshot(
      projects: [],
      workspaces: [],
      tasks: [],
      findings: [],
      events: [],
      artifacts: []);

  factory AxSnapshot.fromJson(Map<String, dynamic> json) => AxSnapshot(
        workspaceId: json['workspaceId'] as String?,
        viewer: json['viewer'] == null
            ? null
            : AxViewer.fromJson(
                Map<String, dynamic>.from(json['viewer'] as Map)),
        activeRunId: json['activeRunId'] as String?,
        run: json['run'] == null
            ? null
            : AxRun.fromJson(Map<String, dynamic>.from(json['run'] as Map)),
        projects: (json['projects'] as List? ?? const [])
            .map((item) =>
                AxProject.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        workspaces: (json['workspaces'] as List? ?? const [])
            .map((item) =>
                AxWorkspace.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        tasks: (json['tasks'] as List? ?? const [])
            .map((item) =>
                AxTask.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        findings: (json['findings'] as List? ?? const [])
            .map((item) =>
                AxFinding.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        events: (json['events'] as List? ?? const [])
            .map((item) =>
                AxEvent.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        artifacts: (json['artifacts'] as List? ?? const [])
            .map((item) =>
                AxArtifact.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        candidateOutputs: (json['candidateOutputs'] as List? ?? const [])
            .map((item) => AxCandidateOutput.fromJson(
                Map<String, dynamic>.from(item as Map)))
            .toList(),
        synthesisDecision: json['synthesisDecision'] == null
            ? null
            : AxSynthesisDecision.fromJson(
                Map<String, dynamic>.from(json['synthesisDecision'] as Map)),
      );
}

enum AxAttentionKind {
  invitation,
  needsInput,
  failedExecution,
  workerProblem,
  workspaceProblem,
  completed,
  finding,
  general,
}

class AxHomeAttentionItem {
  const AxHomeAttentionItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.timestampDisplay,
    this.categoryLabel,
    this.kind = AxAttentionKind.general,
    this.projectId,
    this.workstreamId,
    this.actionLabel,
    this.invitation,
    this.severity = 'info',
    this.isUnread = true,
    this.isActionable = true,
    this.createdAt,
  });

  final String id;
  final String title;
  final String subtitle;
  final String timestampDisplay;
  final String? categoryLabel;
  final AxAttentionKind kind;
  final String? projectId;
  final String? workstreamId;
  final String? actionLabel;
  final AxProjectInvitation? invitation;
  final String severity;
  final bool isUnread;
  final bool isActionable;
  final DateTime? createdAt;

  int get priorityOrder {
    switch (kind) {
      case AxAttentionKind.invitation:
        return 1;
      case AxAttentionKind.needsInput:
        return 2;
      case AxAttentionKind.failedExecution:
        return 3;
      case AxAttentionKind.workerProblem:
        return 4;
      case AxAttentionKind.workspaceProblem:
        return 5;
      case AxAttentionKind.completed:
        return 6;
      case AxAttentionKind.finding:
        return 7;
      case AxAttentionKind.general:
        return 8;
    }
  }
}

class AxContinueWorkItem {
  const AxContinueWorkItem({
    required this.projectId,
    required this.projectName,
    required this.workstreamId,
    required this.workstreamTitle,
    required this.collaboratorsDisplay,
    required this.lastMessageSnippet,
    required this.lastActivityDisplay,
  });

  final String projectId;
  final String projectName;
  final String workstreamId;
  final String workstreamTitle;
  final String collaboratorsDisplay;
  final String lastMessageSnippet;
  final String lastActivityDisplay;
}

class AxProductUpdate {
  const AxProductUpdate({
    required this.id,
    required this.title,
    required this.summary,
    required this.publishedAt,
    required this.dateDisplay,
    this.actionUrl,
    this.learnMoreUrl,
  });

  final String id;
  final String title;
  final String summary;
  final String publishedAt;
  final String dateDisplay;
  final String? actionUrl;
  final String? learnMoreUrl;
}

class AxAiUpdate {
  const AxAiUpdate({
    required this.id,
    required this.workerTypeId,
    required this.workerDisplayName,
    required this.title,
    required this.detail,
    this.actionLabel,
  });

  final String id;
  final String workerTypeId;
  final String workerDisplayName;
  final String title;
  final String detail;
  final String? actionLabel;
}
