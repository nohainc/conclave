enum AxNotificationKind {
  completed,
  failed,
  approvalRequired,
  workspaceOffline,
  workerCredentialProblem,
  workerInstallFailed,
  invitationReceived,
}

enum AxNotificationPriority { high, normal, low }

enum AxNotificationTarget { run, workspaces, workspace }

/// Filters realtime noise from actionable team notifications. Progress,
/// discussion, queue, checkout, and lease updates update read models but do
/// not interrupt the user.
bool isMeaningfulRealtimeNotification(String type) => {
      'run.input_required',
      'run.approval_required',
      'workstream.needs_input',
      'workstream.completed',
      'workstream.failed',
      'workstream.account.problem',
      'workstream.grant.problem',
      'workstream.recovery.required',
      'run.completed',
      'run.failed',
      'assignment.failed',
      'account.expired',
      'credential.expired',
      'worker.install.failed',
      'worker.install_failed',
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
    'run.completed' || 'assignment.completed' => AxNotificationKind.completed,
    'run.failed' ||
    'task.failed' ||
    'assignment.failed' =>
      AxNotificationKind.failed,
    'run.input_required' ||
    'run.approval_required' ||
    'workstream.needs_input' =>
      AxNotificationKind.approvalRequired,
    'workstream.completed' => AxNotificationKind.completed,
    'workstream.failed' ||
    'workstream.grant.problem' ||
    'workstream.recovery.required' =>
      AxNotificationKind.failed,
    'workstream.account.problem' => AxNotificationKind.workerCredentialProblem,
    'workspace.offline' ||
    'workspace.stale' =>
      AxNotificationKind.workspaceOffline,
    'account.expired' ||
    'credential.expired' =>
      AxNotificationKind.workerCredentialProblem,
    'worker.install.failed' ||
    'worker.install_failed' =>
      AxNotificationKind.workerInstallFailed,
    'workspace.invitation.received' ||
    'invitation.received' =>
      AxNotificationKind.invitationReceived,
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
        AxNotificationKind.completed => 'The Run is ready to review.',
        AxNotificationKind.failed => 'The Run needs attention.',
        AxNotificationKind.approvalRequired =>
          'A response is needed before the Run can continue.',
        AxNotificationKind.workspaceOffline =>
          'A Workspace is offline and may need to reconnect.',
        AxNotificationKind.workerCredentialProblem =>
          'A Worker connection needs to be re-authenticated.',
        AxNotificationKind.workerInstallFailed =>
          'A Worker could not connect to a Workspace.',
        AxNotificationKind.invitationReceived =>
          'You received a Workspace invitation.',
      };
  final timestamp =
      DateTime.tryParse(_optionalString(event['timestamp']) ?? '')?.toLocal() ??
          DateTime.now();
  final eventId = _optionalString(event['eventId']) ??
      '$type:${runId ?? projectId ?? 'workspace'}:${timestamp.microsecondsSinceEpoch}';
  final target = switch (kind) {
    AxNotificationKind.completed ||
    AxNotificationKind.failed ||
    AxNotificationKind.approvalRequired =>
      AxNotificationTarget.run,
    AxNotificationKind.workspaceOffline => AxNotificationTarget.workspaces,
    AxNotificationKind.workerCredentialProblem =>
      AxNotificationTarget.workspace,
    AxNotificationKind.workerInstallFailed => AxNotificationTarget.workspace,
    AxNotificationKind.invitationReceived => AxNotificationTarget.workspace,
  };

  return AxNotification(
    id: eventId,
    kind: kind,
    title: switch (kind) {
      AxNotificationKind.completed => 'Run completed',
      AxNotificationKind.failed => 'Run failed',
      AxNotificationKind.approvalRequired => 'Action needed',
      AxNotificationKind.workspaceOffline => 'Workspace offline',
      AxNotificationKind.workerCredentialProblem => 'Worker connection expired',
      AxNotificationKind.workerInstallFailed => 'Worker connection failed',
      AxNotificationKind.invitationReceived => 'Invitation received',
    },
    message: message,
    createdAt: timestamp,
    priority: switch (kind) {
      AxNotificationKind.approvalRequired ||
      AxNotificationKind.failed ||
      AxNotificationKind.workerCredentialProblem =>
        AxNotificationPriority.high,
      AxNotificationKind.workspaceOffline ||
      AxNotificationKind.workerInstallFailed ||
      AxNotificationKind.invitationReceived =>
        AxNotificationPriority.normal,
      AxNotificationKind.completed => AxNotificationPriority.low,
    },
    projectId: projectId,
    runId: runId,
    workspaceId: workspaceId,
    workerId: workerId,
    target: target,
  );
}

String? _optionalString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;
