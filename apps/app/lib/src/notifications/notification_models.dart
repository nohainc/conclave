enum AxNotificationKind {
  // Workstream
  workstreamNeedsInput,
  workstreamCompleted,
  workstreamFailed,

  // Workflow Run
  workflowRunCompleted,
  workflowRunFailed,
  workflowRunNeedsApproval,

  // Worker
  workerCredentialProblem,
  workerInstallFailed,

  // Workspace
  workspaceOffline,

  // Project
  projectInvitationReceived,

  // Backwards-compatibility aliases
  completed,
  failed,
  approvalRequired,
  invitationReceived,
}

enum AxNotificationPriority { high, normal, low }

enum AxNotificationTarget {
  workstream,
  workflowRun,
  run,
  workspaces,
  workspace,
  project,
}

/// Filters realtime noise from actionable team notifications. Progress,
/// discussion, queue, and lease updates update read models but do
/// not interrupt the user.
bool isMeaningfulRealtimeNotification(String type) => {
      'run.input_required',
      'run.approval_required',
      'workflow_run.input_required',
      'workflow_run.approval_required',
      'workstream.needs_input',
      'workstream.completed',
      'workstream.failed',
      'workstream.account.problem',
      'workstream.grant.problem',
      'workstream.recovery.required',
      'run.completed',
      'run.failed',
      'workflow_run.completed',
      'workflow_run.failed',
      'assignment.failed',
      'assignment.completed',
      'account.expired',
      'credential.expired',
      'worker.credential.expired',
      'worker.install.failed',
      'worker.install_failed',
      'workspace.offline',
      'workspace.stale',
      'workspace.invitation.received',
      'project.invitation.received',
      'invitation.received',
    }.contains(type);

class AxNotification {
  const AxNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.message,
    required this.createdAt,
    required this.priority,
    this.projectId,
    this.workstreamId,
    this.runId,
    this.workspaceId,
    this.workerId,
    this.target,
    this.read = false,
  });

  final String id;
  final AxNotificationKind kind;
  final String title;
  final String message;
  final DateTime createdAt;
  final AxNotificationPriority priority;
  final String? projectId;
  final String? workstreamId;
  final String? runId;
  final String? workspaceId;
  final String? workerId;
  final AxNotificationTarget? target;
  final bool read;

  AxNotification markRead() => AxNotification(
        id: id,
        kind: kind,
        title: title,
        message: message,
        createdAt: createdAt,
        priority: priority,
        projectId: projectId,
        workstreamId: workstreamId,
        runId: runId,
        workspaceId: workspaceId,
        workerId: workerId,
        target: target,
        read: true,
      );
}

AxNotification? notificationFromRealtimeEvent(
  Map<String, dynamic> event,
) {
  final type = event['type'];
  if (type is! String) return null;
  final kind = switch (type) {
    'workstream.needs_input' => AxNotificationKind.workstreamNeedsInput,
    'workstream.completed' => AxNotificationKind.workstreamCompleted,
    'workstream.failed' ||
    'workstream.grant.problem' ||
    'workstream.recovery.required' =>
      AxNotificationKind.workstreamFailed,
    'workflow_run.completed' => AxNotificationKind.workflowRunCompleted,
    'run.completed' ||
    'assignment.completed' =>
      AxNotificationKind.workflowRunCompleted,
    'workflow_run.failed' => AxNotificationKind.workflowRunFailed,
    'run.failed' ||
    'task.failed' ||
    'assignment.failed' =>
      AxNotificationKind.workflowRunFailed,
    'workflow_run.approval_required' ||
    'workflow_run.input_required' =>
      AxNotificationKind.workflowRunNeedsApproval,
    'run.input_required' ||
    'run.approval_required' =>
      AxNotificationKind.workflowRunNeedsApproval,
    'workstream.account.problem' ||
    'account.expired' ||
    'credential.expired' ||
    'worker.credential.expired' =>
      AxNotificationKind.workerCredentialProblem,
    'workspace.offline' ||
    'workspace.stale' =>
      AxNotificationKind.workspaceOffline,
    'worker.install.failed' ||
    'worker.install_failed' =>
      AxNotificationKind.workerInstallFailed,
    'project.invitation.received' ||
    'workspace.invitation.received' ||
    'invitation.received' =>
      AxNotificationKind.projectInvitationReceived,
    _ => null,
  };
  if (kind == null) return null;

  final payload = event['payload'];
  final payloadMap = payload is Map
      ? Map<String, dynamic>.from(payload)
      : const <String, dynamic>{};
  final runId =
      _optionalString(event['runId']) ?? _optionalString(payloadMap['runId']);
  final projectId = _optionalString(event['projectId']) ??
      _optionalString(payloadMap['projectId']);
  final workstreamId = _optionalString(event['workstreamId']) ??
      _optionalString(event['workstream_id']) ??
      _optionalString(payloadMap['workstreamId']) ??
      _optionalString(payloadMap['workstream_id']);
  final workspaceId = _optionalString(event['workspaceId']) ??
      _optionalString(event['workspace_id']) ??
      _optionalString(payloadMap['workspaceId']) ??
      _optionalString(payloadMap['workspace_id']);
  final workerId = _optionalString(event['workerId']) ??
      _optionalString(event['worker_id']) ??
      _optionalString(payloadMap['workerId']) ??
      _optionalString(payloadMap['worker_id']);
  final message = _optionalString(payloadMap['prompt']) ??
      _optionalString(payloadMap['summary']) ??
      _optionalString(payloadMap['error']) ??
      switch (kind) {
        AxNotificationKind.workstreamNeedsInput =>
          'Your input or decision is needed in the Workstream.',
        AxNotificationKind.workstreamCompleted =>
          'Workstream activity has completed.',
        AxNotificationKind.workstreamFailed =>
          'Workstream activity failed and needs attention.',
        AxNotificationKind.workflowRunCompleted ||
        AxNotificationKind.completed =>
          'The Workflow Run is ready to review.',
        AxNotificationKind.workflowRunFailed ||
        AxNotificationKind.failed =>
          'The Workflow Run needs attention.',
        AxNotificationKind.workflowRunNeedsApproval ||
        AxNotificationKind.approvalRequired =>
          'Approval is required before the Workflow Run can continue.',
        AxNotificationKind.workspaceOffline =>
          'A Workspace is offline and may need to reconnect.',
        AxNotificationKind.workerCredentialProblem =>
          'A Worker connection needs to be re-authenticated.',
        AxNotificationKind.workerInstallFailed =>
          'A Worker could not connect to a Workspace.',
        AxNotificationKind.projectInvitationReceived ||
        AxNotificationKind.invitationReceived =>
          'You received a Project invitation.',
      };
  final timestamp =
      DateTime.tryParse(_optionalString(event['timestamp']) ?? '')?.toLocal() ??
          DateTime.now();
  final eventId = _optionalString(event['eventId']) ??
      '$type:${workstreamId ?? runId ?? projectId ?? 'workspace'}:${timestamp.microsecondsSinceEpoch}';
  final target = switch (kind) {
    AxNotificationKind.workstreamNeedsInput ||
    AxNotificationKind.workstreamCompleted ||
    AxNotificationKind.workstreamFailed =>
      AxNotificationTarget.workstream,
    AxNotificationKind.workflowRunCompleted ||
    AxNotificationKind.workflowRunFailed ||
    AxNotificationKind.workflowRunNeedsApproval ||
    AxNotificationKind.completed ||
    AxNotificationKind.failed ||
    AxNotificationKind.approvalRequired =>
      AxNotificationTarget.workflowRun,
    AxNotificationKind.workspaceOffline => AxNotificationTarget.workspaces,
    AxNotificationKind.workerCredentialProblem =>
      AxNotificationTarget.workspace,
    AxNotificationKind.workerInstallFailed => AxNotificationTarget.workspace,
    AxNotificationKind.projectInvitationReceived ||
    AxNotificationKind.invitationReceived =>
      AxNotificationTarget.project,
  };

  return AxNotification(
    id: eventId,
    kind: kind,
    title: switch (kind) {
      AxNotificationKind.workstreamNeedsInput => 'Workstream needs input',
      AxNotificationKind.workstreamCompleted => 'Workstream completed',
      AxNotificationKind.workstreamFailed => 'Workstream failed',
      AxNotificationKind.workflowRunCompleted ||
      AxNotificationKind.completed =>
        'Workflow Run completed',
      AxNotificationKind.workflowRunFailed ||
      AxNotificationKind.failed =>
        'Workflow Run failed',
      AxNotificationKind.workflowRunNeedsApproval ||
      AxNotificationKind.approvalRequired =>
        'Action needed',
      AxNotificationKind.workspaceOffline => 'Workspace offline',
      AxNotificationKind.workerCredentialProblem => 'Worker connection expired',
      AxNotificationKind.workerInstallFailed => 'Worker connection failed',
      AxNotificationKind.projectInvitationReceived ||
      AxNotificationKind.invitationReceived =>
        'Invitation received',
    },
    message: message,
    createdAt: timestamp,
    priority: switch (kind) {
      AxNotificationKind.workstreamNeedsInput ||
      AxNotificationKind.workstreamFailed ||
      AxNotificationKind.workflowRunNeedsApproval ||
      AxNotificationKind.workflowRunFailed ||
      AxNotificationKind.approvalRequired ||
      AxNotificationKind.failed ||
      AxNotificationKind.workerCredentialProblem =>
        AxNotificationPriority.high,
      AxNotificationKind.workspaceOffline ||
      AxNotificationKind.workerInstallFailed ||
      AxNotificationKind.projectInvitationReceived ||
      AxNotificationKind.invitationReceived =>
        AxNotificationPriority.normal,
      AxNotificationKind.workstreamCompleted ||
      AxNotificationKind.workflowRunCompleted ||
      AxNotificationKind.completed =>
        AxNotificationPriority.low,
    },
    projectId: projectId,
    workstreamId: workstreamId,
    runId: runId,
    workspaceId: workspaceId,
    workerId: workerId,
    target: target,
  );
}

String? _optionalString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;
