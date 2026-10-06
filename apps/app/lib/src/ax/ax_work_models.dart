import 'ax_models.dart';

class AxWorkRequestStatus {
  const AxWorkRequestStatus({
    required this.status,
    this.text,
    this.error,
    this.errorCode,
    this.errorMessage,
    this.workflowId,
    this.workflowVersion,
    this.workflowName,
    this.requestedByUserId,
    this.requestedByName,
    this.originalRequest,
    this.createdAt,
    this.steps = const [],
  });

  final String status;
  final String? text;
  final String? error;
  final String? errorCode;
  final String? errorMessage;
  final String? workflowId;
  final int? workflowVersion;
  final String? workflowName;
  final String? requestedByUserId;
  final String? requestedByName;
  final String? originalRequest;
  final String? createdAt;
  final List<AxWorkRequestStep> steps;
}

class AxWorkRequestStep {
  const AxWorkRequestStep({
    required this.kind,
    required this.status,
    required this.workerId,
    this.workerTypeId,
    this.workerDisplayName,
    this.engineVersion,
    this.profileDefinitionId,
    this.profileReleaseVersion,
    this.providerToolName,
    this.providerToolVersion,
    this.model,
    this.testSummary,
    this.startedAt,
    this.updatedAt,
    this.elapsedMs,
    this.completedAt,
    this.resultText,
    this.assignmentId,
    this.sessionPolicy,
    this.errorCode,
    this.errorMessage,
    this.retrySessionStrategy,
  });

  final String kind;
  final String status;
  final String? workerId;
  final String? workerTypeId;
  final String? workerDisplayName;
  final String? engineVersion;
  final String? profileDefinitionId;
  final int? profileReleaseVersion;
  final String? providerToolName;
  final String? providerToolVersion;
  final String? model;
  final String? testSummary;
  final String? startedAt;
  final String? updatedAt;
  final int? elapsedMs;
  final String? completedAt;
  final String? resultText;
  final String? assignmentId;
  final String? sessionPolicy;
  final String? errorCode;
  final String? errorMessage;
  final String? retrySessionStrategy;

  factory AxWorkRequestStep.fromJson(Map<String, dynamic> json) =>
      AxWorkRequestStep(
        kind: json['kind']?.toString() ?? 'implement',
        status: json['status']?.toString() ?? 'queued',
        workerId: json['workerId']?.toString(),
        workerTypeId: json['workerTypeId']?.toString(),
        workerDisplayName: json['workerDisplayName']?.toString(),
        engineVersion: json['engineVersion']?.toString(),
        profileDefinitionId: json['profileDefinitionId']?.toString(),
        profileReleaseVersion: json['profileReleaseVersion'] as int?,
        providerToolName: json['providerToolName']?.toString(),
        providerToolVersion: json['providerToolVersion']?.toString(),
        model: json['model']?.toString(),
        testSummary: json['testSummary']?.toString(),
        startedAt: json['startedAt']?.toString(),
        updatedAt: json['updatedAt']?.toString(),
        elapsedMs: json['elapsedMs'] as int?,
        completedAt: json['completedAt']?.toString(),
        resultText: json['resultText']?.toString(),
        assignmentId: json['assignmentId']?.toString(),
        sessionPolicy: json['sessionPolicy']?.toString(),
        errorCode: json['errorCode']?.toString(),
        errorMessage: json['errorMessage']?.toString(),
        retrySessionStrategy: json['retrySessionStrategy']?.toString(),
      );
}

class AxWorkRequest {
  const AxWorkRequest({
    required this.id,
    required this.requestedByName,
    this.requestedByUserId,
    required this.prompt,
    required this.workflowId,
    required this.workflowVersion,
    this.workflowName,
    required this.status,
    required this.createdAt,
    required this.steps,
    this.finalText,
    this.error,
  });

  final String id;
  final String requestedByName;
  final String? requestedByUserId;
  final String prompt;
  final String workflowId;
  final int workflowVersion;
  final String? workflowName;
  final String status;
  final String createdAt;
  final List<AxWorkRequestStep> steps;
  final String? finalText;
  final String? error;

  String? get testSummary {
    for (final step in steps) {
      if (step.kind == 'test' && step.testSummary != null) {
        return step.testSummary;
      }
    }
    return null;
  }

  factory AxWorkRequest.fromJson(Map<String, dynamic> json) {
    final snapshot = json['workflowSnapshot'];
    final snapshotName = snapshot is Map &&
            snapshot['id'] == json['workflowId'] &&
            snapshot['version'] == json['workflowVersion']
        ? snapshot['name']
        : null;
    final steps = (json['steps'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxWorkRequestStep.fromJson(
              Map<String, dynamic>.from(item),
            ))
        .toList();
    return AxWorkRequest(
      id: json['id']?.toString() ?? '',
      requestedByName: json['requestedByName']?.toString() ?? 'Team member',
      requestedByUserId:
          (json['requestedByUserId'] ?? json['requested_by_user_id'])
              ?.toString(),
      prompt: json['prompt']?.toString() ?? '',
      workflowId: json['workflowId']?.toString() ?? 'direct',
      workflowVersion: json['workflowVersion'] as int? ?? 1,
      workflowName: (snapshotName ?? json['workflowName'])?.toString(),
      status: json['status']?.toString() ?? 'queued',
      createdAt: json['createdAt']?.toString() ?? '',
      steps: steps,
      finalText: json['finalText']?.toString(),
      error: json['error']?.toString(),
    );
  }
}

/// Public metadata used to show which desktop client requested browser approval.
class AxDesktopAuthIntentStatus {
  const AxDesktopAuthIntentStatus({
    required this.status,
    required this.clientName,
    required this.audience,
  });

  final String status;
  final String clientName;
  final String audience;

  /// Resolve the application name from the server-controlled audience. The
  /// display label never trusts a caller-provided clientName.
  String? get applicationName => switch (audience) {
        'conclave.desktop.management' => 'Conclave Workspace',
        'conclave.profile-lab.management' => 'Conclave Profile Lab',
        _ => null,
      };

  bool get canApprove => status == 'pending' && applicationName != null;

  @override
  bool operator ==(Object other) =>
      other is AxDesktopAuthIntentStatus &&
      other.status == status &&
      other.clientName == clientName &&
      other.audience == audience;

  @override
  int get hashCode => Object.hash(status, clientName, audience);

  factory AxDesktopAuthIntentStatus.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    final clientName = json['clientName'];
    final audience = json['audience'];
    if (status is! String ||
        !const {'pending', 'approved', 'claimed', 'denied', 'expired'}
            .contains(status) ||
        clientName is! String ||
        audience is! String) {
      throw const FormatException('Sign-in request metadata is malformed');
    }
    return AxDesktopAuthIntentStatus(
      status: status,
      clientName: clientName,
      audience: audience,
    );
  }
}

abstract interface class AxDataSource {
  Future<AxSession> loadSession();
  Future<void> logout();
  Future<void> signInWithEmail({
    required String email,
    required String password,
  });
  Future<void> signUpWithEmail({
    required String name,
    required String email,
    required String password,
  });
  Future<void> requestPasswordReset({required String email});
  Future<void> resetPassword({
    required String token,
    required String password,
  });
  Future<AxProject> createProject({
    required String name,
    String? description,
    String? instructions,
  });
  Future<AxProject> updateProject({
    required String projectId,
    String? name,
    String? description,
    String? instructions,
    Map<String, dynamic>? settings,
  });
  Future<void> archiveProject({required String projectId});
  Future<void> deleteProject({required String projectId});
  Future<List<AxProjectMember>> loadProjectMembers({
    required String projectId,
  }) async =>
      throw UnimplementedError('Project collaboration is not available');
  Future<List<AxProjectInvitation>> loadProjectInvitations({
    required String projectId,
  }) async =>
      throw UnimplementedError('Project collaboration is not available');
  Future<List<AxAuditEntry>> loadProjectAudit({
    required String projectId,
  }) async =>
      throw UnimplementedError('Project collaboration is not available');
  Future<void> inviteProjectMember({
    required String projectId,
    required String email,
    required String role,
  }) async =>
      throw UnimplementedError('Project collaboration is not available');
  Future<void> changeProjectMemberRole({
    required String projectId,
    required String userId,
    required String role,
  }) async =>
      throw UnimplementedError('Project collaboration is not available');
  Future<void> removeProjectMember({
    required String projectId,
    required String userId,
  }) async =>
      throw UnimplementedError('Project collaboration is not available');
  Future<void> expireProjectInvitation({
    required String projectId,
    required String invitationId,
  }) async =>
      throw UnimplementedError('Project collaboration is not available');
  Future<AxAccountSecurity> loadAccountSecurity();
  Future<void> revokeAccountSession(String token);
  Future<Uri> beginAccountLink(String provider, Uri returnTo);
  Future<void> registerPasskey(String name);
  Future<void> deletePasskey(String id);
  Future<void> signInWithPasskey();
  Future<void> approveDesktopAuthIntent({
    required String intentId,
  });
  Future<AxDesktopAuthIntentStatus> loadDesktopAuthIntentStatus(
      {required String intentId});
  Future<void> denyDesktopAuthIntent({required String intentId});
  Future<List<AxWorkspace>> loadWorkspaces();
  Future<List<AxProject>> loadProjects({bool includeArchived = false});
  Future<List<Map<String, dynamic>>> loadProjectWorkspaces({
    required String projectId,
  });
  Future<void> requestProjectWorkspace({
    required String projectId,
    required String workspaceId,
    List<String> allowedPermissions = const [],
  });
  Future<void> updateWorkspaceProjectPermissions({
    required String grantId,
    required List<String> allowedPermissions,
  });
  Future<void> revokeWorkspaceProjectGrant({
    required String grantId,
  });
  Future<List<AxWorkstream>> loadProjectWorkstreams({
    required String projectId,
  });
  Future<AxWorkstream> createWorkstream({
    required String projectId,
    required String name,
  });
  Future<AxWorkstream> updateWorkstream({
    required String workstreamId,
    String? name,
    String? status,
    Map<String, dynamic>? workConfig,
  });
  Future<void> deleteWorkstream({required String workstreamId});
  Future<String> createWorkRequest({
    required String workstreamId,
    required String workflowId,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
  }) async =>
      throw UnimplementedError('Work Request execution is not available');
  Future<List<String>> validateWorkRequestEligibility({
    required String workstreamId,
    required String workflowId,
    List<Map<String, dynamic>> attachments = const [],
  }) async =>
      const [];
  Future<AxWorkRequestStatus> loadWorkRequest({
    required String workRequestId,
  }) async =>
      throw UnimplementedError('Work Request status is not available');
  Future<void> retryWorkRequestStep({
    required String workRequestId,
    required String stepKind,
    String? sessionStrategy,
  }) async =>
      throw UnimplementedError('Work Request retry is not available');
  Future<void> cancelWorkRequest({
    required String workRequestId,
  }) async =>
      throw UnimplementedError('Work Request cancellation is not available');
  Future<List<AxWorkRequest>> loadWorkstreamWorkRequests({
    required String workstreamId,
    bool activeOnly = false,
  }) async =>
      const [];
  Future<List<AxDiscussionMessage>> loadDiscussionMessages({
    required String workstreamId,
  }) async =>
      const [];
  Future<AxDiscussionMessage> sendDiscussionMessage({
    required String workstreamId,
    required String text,
    List<String> references = const [],
  }) async =>
      throw UnimplementedError('Discussion messages are not available');
  Future<AxDiscussionMessage> editDiscussionMessage({
    required String messageId,
    required String text,
    List<String> references = const [],
  }) async =>
      throw UnimplementedError('Discussion messages are not available');
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async => const [];
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async =>
      const [];
  Future<AxWorkspace> updateWorkspace({
    required String workspaceId,
    required String name,
  });
  Future<List<AxWorkspaceMember>> loadWorkspaceMembers(
      {required String workspaceId});
  Future<List<AxWorkspaceInvitation>> loadWorkspaceInvitations(
      {required String workspaceId});
  Future<List<AxAuditEntry>> loadWorkspaceAudit({required String workspaceId});
  Future<void> inviteWorkspaceMember({
    required String workspaceId,
    required String email,
    required String role,
  });
  Future<void> changeWorkspaceMemberRole({
    required String workspaceId,
    required String userId,
    required String role,
  });
  Future<void> setWorkspaceMemberStatus({
    required String workspaceId,
    required String userId,
    required String status,
  });
  Future<void> expireWorkspaceInvitation({
    required String workspaceId,
    required String invitationId,
  });

  /// Composes the current AX view from focused Project and Workspace APIs.
  Future<AxSnapshot> loadReadModels({String? projectId, String? workspaceId});
  Future<void> controlRun(String runId, String command);
  Future<void> respondToRunPrompt(String runId, String response);
  Future<void> revokeWorkspace({required String workspaceId});
}
